import AVFoundation
import CoreMedia
import Foundation

/// Owns the `AVCaptureSession` and hands raw frames to a delegate.
///
/// The session is owned outright rather than delegated to a streaming library,
/// because later milestones need the same buffers for local recording (M3) and
/// Metal monitoring overlays (M4).
final class CaptureEngine: NSObject {

    enum Resolution: String, CaseIterable, Identifiable {
        case hd1080 = "1080p"
        case uhd4K  = "4K"

        var id: String { rawValue }

        var dimensions: (width: Int32, height: Int32) {
            switch self {
            case .hd1080: return (1920, 1080)
            case .uhd4K:  return (3840, 2160)
            }
        }

        /// The earlier values were far too conservative. Measured throughput
        /// over the cable was ~12 Mb/s with the link barely working — USB 2.0
        /// offers roughly 280 Mb/s, so bitrate was never the constraint.
        /// Detailed scenes genuinely need this many bits; starving them is
        /// what produces shimmering artefacts in fine texture.
        ///
        /// Doubling the frame rate does not double the requirement —
        /// consecutive frames are more alike at 60fps, so each costs less.
        func defaultBitrate(fps: Int32) -> Int {
            let base: Int
            switch self {
            case .hd1080: base = 25_000_000
            case .uhd4K:  base = 60_000_000
            }
            return fps >= 60 ? base * 3 / 2 : base
        }
    }

    /// Called on `sessionQueue` for every captured frame.
    var onFrame: ((CVPixelBuffer, CMTime, CMTime) -> Void)?

    let session = AVCaptureSession()
    private(set) var device: AVCaptureDevice?
    private(set) var activeResolution: Resolution = .hd1080

    enum FrameRate: Int32, CaseIterable, Identifiable {
        case fps30 = 30
        case fps60 = 60

        var id: Int32 { rawValue }
        var label: String { "\(rawValue)fps" }
    }

    private let sessionQueue = DispatchQueue(label: "dev.ryanmj.xrcam.capture")
    private let output = AVCaptureVideoDataOutput()
    private(set) var frameRate: FrameRate = .fps30

    var fps: Int32 { frameRate.rawValue }

    /// Exposed so manual controls can cap shutter at the frame interval —
    /// exposure can never outlast one frame.
    var frameDuration: CMTime { CMTime(value: 1, timescale: fps) }

    // MARK: - Configuration

    func configure(resolution: Resolution, frameRate: FrameRate) throws {
        activeResolution = resolution
        self.frameRate = frameRate

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // The preset must be overridden by an explicit activeFormat below,
        // otherwise AVFoundation silently reverts our frame-rate pinning.
        session.sessionPreset = .inputPriority

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            throw CaptureError.noCamera
        }
        self.device = device

        // Inputs
        session.inputs.forEach { session.removeInput($0) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)

        // Format
        let target = resolution.dimensions
        guard let format = Self.bestFormat(for: device,
                                           width: target.width,
                                           height: target.height,
                                           fps: Double(fps)) else {
            throw CaptureError.formatUnavailable("\(resolution.rawValue) \(frameRate.label)")
        }

        try device.lockForConfiguration()
        device.activeFormat = format
        // Pinning min and max to the same value locks the frame rate. Left
        // free, iOS drops frame rate in low light, which desynchronises a
        // stream whose consumer was told to expect a constant 30fps.
        let duration = CMTime(value: 1, timescale: fps)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()

        // Output — 420v is what VideoToolbox wants, avoiding a conversion pass.
        session.outputs.forEach { session.removeOutput($0) }
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]
        // Backpressure at the source: if the encoder falls behind, drop the
        // newest frame rather than accumulate latency.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)

        guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            connection.videoOrientation = .landscapeRight
            // Stabilization is explicitly OFF. iOS stabilizes by buffering
            // frames for lookahead, which shows up as capture latency before
            // a single byte reaches the encoder. For a tripod/desk-mounted
            // streaming camera, latency is worth more than smoothing.
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - Format selection

    /// Prefers the smallest format meeting the target, to avoid picking a
    /// binned or high-frame-rate variant that costs bandwidth for nothing.
    private static func bestFormat(for device: AVCaptureDevice,
                                   width: Int32,
                                   height: Int32,
                                   fps: Double) -> AVCaptureDevice.Format? {
        device.formats
            .filter { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width == width, dims.height == height else { return false }

                let supportsRate = format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= fps && fps <= $0.maxFrameRate
                }
                guard supportsRate else { return false }

                let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                return subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }
            .min { a, b in
                let ra = a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                let rb = b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                return ra < rb
            }
    }

    enum CaptureError: Error, LocalizedError {
        case noCamera
        case cannotAddInput
        case cannotAddOutput
        case formatUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .noCamera:                return "No back camera available"
            case .cannotAddInput:          return "Could not attach the camera input"
            case .cannotAddOutput:         return "Could not attach the video output"
            case .formatUnavailable(let r): return "This device has no \(r) 30fps format"
            }
        }
    }
}

// MARK: - Frame delivery

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        onFrame?(pixelBuffer, pts, duration)
    }
}
