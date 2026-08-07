import Foundation
import Network

/// TCP server carrying the Annex-B elementary stream to the PC.
///
/// The phone is deliberately the *server*: `iproxy` forwards a Windows local
/// port to a port the device is listening on, so OBS connects outward to
/// `tcp://127.0.0.1:9000` and usbmuxd carries it down the cable.
final class TCPVideoServer {

    enum State: Equatable {
        case idle
        case listening
        case connected
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?

    /// Raised when a stalled connection drains, so the encoder can insert an
    /// IDR — after dropping frames the decoder needs a fresh reference point.
    var onNeedsKeyframe: (() -> Void)?

    private(set) var framesSent = 0
    private(set) var framesDropped = 0
    private(set) var bytesSent = 0

    /// Sent once on connect. Its presence tells the native OBS plugin that
    /// every frame is length-prefixed; without it the plugin falls back to
    /// splitting on AUDs, which costs a frame of latency because a frame is
    /// only known to have ended once the next one starts arriving.
    private static let framingMagic = Data([0x58, 0x52, 0x43, 0x41,
                                            0x4D, 0x31, 0x00, 0x00]) // "XRCAM1\0\0"

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "dev.ryanmj.xrcam.transport")

    private var listener: NWListener?
    private var connection: NWConnection?

    /// Frames handed to the socket but not yet written.
    private var pendingFrames = 0
    private var pendingBytes = 0
    private var wasStalled = false

    /// Latency is bounded in *frames*, not bytes. A byte budget silently means
    /// a different amount of time at every bitrate — 1 MB is ~0.7s at 12 Mbps
    /// but ~0.3s at 25 — whereas two frames is ~66ms at 30fps regardless.
    private let maxPendingFrames = 2

    /// Secondary guard only, for the case where a single frame is enormous.
    private let maxPendingBytes = 4_000_000

    init(port: UInt16 = 9000) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() {
        stop()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Nagle batches small writes to save packets. For a live video feed
        // that trades latency for bandwidth we do not need.
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        do {
            let listener = try NWListener(using: parameters, on: port)

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.state = .listening
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                default:
                    break
                }
            }

            self.listener = listener
            listener.start(queue: queue)

        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        pendingFrames = 0
        pendingBytes = 0
        state = .idle
    }

    func resetCounters() {
        queue.async {
            self.framesSent = 0
            self.framesDropped = 0
            self.bytesSent = 0
        }
    }

    // MARK: - Connections

    private func accept(_ incoming: NWConnection) {
        // One viewer at a time. A second connection would fork the GOP and see
        // a stream starting mid-picture, so the newest client wins.
        connection?.cancel()
        connection = incoming

        incoming.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.pendingFrames = 0
                self.pendingBytes = 0
                // Announce framing before any frame data goes out.
                incoming.send(content: Self.framingMagic, completion: .idempotent)
                self.state = .connected
                // A client that just attached has no parameter sets yet.
                self.onNeedsKeyframe?()
            case .failed, .cancelled:
                if self.connection === incoming {
                    self.connection = nil
                    self.pendingFrames = 0
                    self.pendingBytes = 0
                    self.state = self.listener == nil ? .idle : .listening
                }
            default:
                break
            }
        }

        incoming.start(queue: queue)
    }

    // MARK: - Sending

    /// Enqueue an encoded frame. Safe to call from the encoder's queue.
    func send(_ data: Data, isKeyframe: Bool) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection,
                  connection.state == .ready else { return }

            if self.pendingFrames >= self.maxPendingFrames
                || self.pendingBytes + data.count > self.maxPendingBytes {
                self.framesDropped += 1
                self.wasStalled = true
                return
            }

            // Coming out of a stall the decoder is mid-GOP and cannot resync
            // until the next IDR, so ask for one immediately.
            if self.wasStalled {
                self.wasStalled = false
                self.onNeedsKeyframe?()
            }

            self.pendingFrames += 1
            self.pendingBytes += data.count

            // Length-prefix and send as one write: Nagle is disabled, so two
            // sends would put the header and payload in separate packets.
            var framed = Data(capacity: data.count + 4)
            withUnsafeBytes(of: UInt32(data.count).bigEndian) {
                framed.append(contentsOf: $0)
            }
            framed.append(data)

            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.pendingFrames -= 1
                self.pendingBytes -= data.count

                if error != nil {
                    self.framesDropped += 1
                } else {
                    self.framesSent += 1
                    self.bytesSent += data.count
                }
            })
        }
    }
}
