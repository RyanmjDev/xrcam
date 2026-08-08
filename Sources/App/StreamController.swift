import AVFoundation
import Combine
import Foundation
import UIKit

/// Wires capture → encode → transport and exposes state to the UI.
@MainActor
final class StreamController: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var transport: TCPVideoServer.State = .idle
    @Published private(set) var statusMessage = "Idle"
    @Published private(set) var framesSent = 0
    @Published private(set) var framesDropped = 0
    @Published private(set) var megabitsPerSecond = 0.0
    @Published private(set) var bitrateMbps = 0.0
    @Published var resolution: CaptureEngine.Resolution = .hd1080
    @Published var frameRate: CaptureEngine.FrameRate = .fps30

    let capture = CaptureEngine()
    let controls = DeviceControls()
    private var encoder: H264Encoder?
    private let server = TCPVideoServer(port: 9000)

    private var statsTimer: Timer?
    private var lastBytes = 0

    init() {
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.transport = state }
        }
        // Fired when a client attaches or the link recovers from a stall.
        server.onNeedsKeyframe = { [weak self] in
            self?.encoder?.requestKeyframe()
        }
        server.onControlMessage = { [weak self] message in
            Task { @MainActor in self?.apply(message) }
        }
    }

    /// Applies a control update from the PC.
    ///
    /// Mode flags go first: switching a group to manual seeds its values from
    /// whatever auto had settled on, which would otherwise overwrite the
    /// values arriving in this same message.
    private func apply(_ message: ControlMessage) {
        if let value = message.exposureAuto { controls.exposureAuto = value }
        if let value = message.focusAuto { controls.focusAuto = value }
        if let value = message.wbAuto { controls.whiteBalanceAuto = value }

        if let value = message.iso { controls.iso = value }
        if let value = message.shutter { controls.shutterDenominator = value }
        if let value = message.lens { controls.lensPosition = value }
        if let value = message.temp { controls.temperature = value }
        if let value = message.tint { controls.tint = value }

        if let mbps = message.bitrateMbps, mbps > 0 {
            let bps = Int(mbps * 1_000_000)
            encoder?.setBitrate(bps)
            bitrateMbps = mbps
        }

        // Last, because it may tear down and rebuild the encoder that the
        // settings above were just applied to.
        applyFormat(
            resolution: message.resolution.flatMap(CaptureEngine.Resolution.init(rawValue:)),
            frameRate: message.fps.flatMap { CaptureEngine.FrameRate(rawValue: Int32($0)) }
        )
    }

    // MARK: - Control

    func start() async {
        guard !isRunning else { return }

        guard await Self.requestCameraAccess() else {
            statusMessage = "Camera access denied — enable it in Settings"
            return
        }

        guard buildPipeline() else { return }

        server.resetCounters()
        server.start()

        // A stream that dies because the screen locked is a bad surprise
        // partway through a recording.
        UIApplication.shared.isIdleTimerDisabled = true

        isRunning = true
        startStatsTimer()
    }

    /// Builds capture + encoder for the current format and starts capturing.
    ///
    /// Kept separate from `start()` so a format change can rebuild this half
    /// while leaving the listener and any connected client untouched — the
    /// plugin renegotiates on the new SPS rather than reconnecting.
    @discardableResult
    private func buildPipeline() -> Bool {
        let dimensions = resolution.dimensions
        let fps = frameRate.rawValue
        // Keep a bitrate already dialled in from OBS across a restart.
        let targetBitrate = bitrateMbps > 0
            ? Int(bitrateMbps * 1_000_000)
            : resolution.defaultBitrate(fps: fps)
        bitrateMbps = Double(targetBitrate) / 1_000_000

        let encoder = H264Encoder(width: dimensions.width,
                                  height: dimensions.height,
                                  fps: fps,
                                  bitrate: targetBitrate)

        // Encoded frames go straight to the socket. The transport decides what
        // to drop; the encoder never blocks on the network.
        encoder.onEncodedFrame = { [weak self] data, isKeyframe in
            self?.server.send(data, isKeyframe: isKeyframe)
        }

        // Noise reduction lives in the OBS plugin, not here. At 60 Mbps the
        // encoder reproduces sensor noise faithfully rather than mangling it,
        // so removing it after decode removes the same noise — without adding
        // GPU load to a 2018 phone that is already capturing and encoding 4K30
        // while charging.
        capture.onFrame = { [weak encoder] pixelBuffer, pts, duration in
            encoder?.encode(pixelBuffer, pts: pts, duration: duration)
        }

        do {
            try capture.configure(resolution: resolution, frameRate: frameRate)
            try encoder.start()
        } catch {
            statusMessage = error.localizedDescription
            return false
        }

        // Rebind after configuration: switching resolution replaces the active
        // format, and any locked exposure/focus/WB has to be re-asserted
        // against the new one.
        if let device = capture.device {
            controls.attach(to: device, frameDuration: capture.frameDuration)
        }

        self.encoder = encoder
        capture.start()

        // A client mid-stream holds parameter sets for the old format and
        // cannot decode the new one until a fresh IDR arrives.
        encoder.requestKeyframe()

        statusMessage = encoder.rejectedProperties.isEmpty
            ? "Waiting for OBS to connect…"
            : "Encoder rejected: \(encoder.rejectedProperties.joined(separator: ", "))"
        return true
    }

    /// Applies a format change from OBS, restarting capture and encode if
    /// running. Both dimensions and frame rate are baked into the encoder, so
    /// neither can be changed in place.
    private func applyFormat(resolution newResolution: CaptureEngine.Resolution?,
                             frameRate newFrameRate: CaptureEngine.FrameRate?) {
        let targetResolution = newResolution ?? resolution
        let targetFrameRate = newFrameRate ?? frameRate

        guard targetResolution != resolution || targetFrameRate != frameRate else { return }

        resolution = targetResolution
        frameRate = targetFrameRate
        guard isRunning else { return }

        capture.stop()
        capture.onFrame = nil
        encoder?.stop()
        encoder = nil
        buildPipeline()
    }

    func stop() {
        guard isRunning else { return }

        capture.stop()
        capture.onFrame = nil
        encoder?.stop()
        encoder = nil
        server.stop()

        UIApplication.shared.isIdleTimerDisabled = false

        statsTimer?.invalidate()
        statsTimer = nil

        isRunning = false
        megabitsPerSecond = 0
        statusMessage = "Idle"
    }

    // MARK: - Stats

    private func startStatsTimer() {
        lastBytes = 0
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
    }

    private func refreshStats() {
        framesSent = server.framesSent
        framesDropped = server.framesDropped

        let bytes = server.bytesSent
        let delta = max(0, bytes - lastBytes)
        lastBytes = bytes
        megabitsPerSecond = Double(delta) * 8.0 / 1_000_000.0

        switch transport {
        case .connected:  statusMessage = "Streaming to OBS"
        case .listening:  statusMessage = "Waiting for OBS to connect…"
        case .failed(let error): statusMessage = "Transport error: \(error)"
        case .idle:       statusMessage = "Idle"
        }
    }

    private static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }
}
