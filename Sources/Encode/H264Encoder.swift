import CoreMedia
import Foundation
import VideoToolbox

/// Hardware H.264 encoder producing an Annex-B elementary stream.
///
/// ffmpeg (and therefore OBS) reads a bare Annex-B stream with `-f h264`, which
/// is why this avoids MPEG-TS muxing entirely. The cost is that the stream
/// carries no audio and no timestamps — OBS is told the frame rate explicitly
/// via its `framerate=30` FFmpeg option.
final class H264Encoder {

    /// Emitted on the encoder's own queue. `isKeyframe` lets the transport
    /// decide what is safe to drop under backpressure.
    var onEncodedFrame: ((Data, _ isKeyframe: Bool) -> Void)?

    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "dev.ryanmj.xrcam.encoder")

    private let width: Int32
    private let height: Int32
    private let fps: Int32
    private let bitrate: Int

    /// Set when the transport recovers from a stall — the next frame is forced
    /// to be an IDR so a re-joining decoder is not stuck on a dangling GOP.
    private var forceKeyframeNext = false

    private static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    init(width: Int32, height: Int32, fps: Int32, bitrate: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() throws {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,          // using the block-based encode API
            refcon: nil,
            compressionSessionOut: &created
        )

        guard status == noErr, let created else {
            throw EncoderError.sessionCreationFailed(status)
        }

        // Low-latency configuration. RealTime tells VideoToolbox to favour
        // consistent frame delivery over compression efficiency, and disabling
        // frame reordering removes B-frames — a reordered stream cannot be
        // emitted until future frames arrive, which is latency we cannot spend.
        set(created, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(created, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(created, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(created, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(created, kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)

        // A keyframe every 2s bounds how long OBS waits for a decodable picture
        // when a source is added or re-enabled mid-stream.
        set(created, kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 2) as CFNumber)
        set(created, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    /// Request that the next encoded frame be an IDR.
    func requestKeyframe() {
        queue.async { self.forceKeyframeNext = true }
    }

    // MARK: - Encoding

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        guard let session else { return }

        var properties: CFDictionary?
        if forceKeyframeNext {
            forceKeyframeNext = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.handleEncoded(sampleBuffer)
        }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let keyframe = Self.isKeyframe(sampleBuffer)
        var out = Data()

        // Parameter sets must precede every keyframe. OBS may attach to the
        // stream at any moment; without a fresh SPS/PPS it cannot initialise a
        // decoder and shows nothing at all.
        if keyframe,
           let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            out.append(Self.parameterSets(from: format))
        }

        out.append(Self.annexB(from: sampleBuffer))
        guard !out.isEmpty else { return }

        onEncodedFrame?(out, keyframe)
    }

    // MARK: - AVCC → Annex-B

    /// VideoToolbox emits AVCC: each NAL unit prefixed with its big-endian
    /// length. An elementary stream instead delimits them with start codes.
    private static func annexB(from sampleBuffer: CMSampleBuffer) -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return Data() }

        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block,
                                          atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer else { return Data() }

        // The prefix is almost always 4 bytes, but it is declared per-format
        // and cheap to read rather than assume.
        var headerLength: Int32 = 4
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &headerLength
            )
        }

        let prefix = Int(headerLength)
        var out = Data(capacity: totalLength + 16)
        var offset = 0

        while offset + prefix <= totalLength {
            var nalLength: UInt32 = 0
            for i in 0..<prefix {
                nalLength = (nalLength << 8) | UInt32(UInt8(bitPattern: pointer[offset + i]))
            }

            let payloadStart = offset + prefix
            guard nalLength > 0, payloadStart + Int(nalLength) <= totalLength else { break }

            out.append(startCode)
            pointer.withMemoryRebound(to: UInt8.self, capacity: totalLength) { bytes in
                out.append(bytes + payloadStart, count: Int(nalLength))
            }

            offset = payloadStart + Int(nalLength)
        }

        return out
    }

    private static func parameterSets(from format: CMFormatDescription) -> Data {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        ) == noErr else { return Data() }

        var out = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { continue }

            out.append(startCode)
            out.append(pointer, count: size)
        }
        return out
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false)
                as? [[CFString: Any]],
              let first = attachments.first else { return true }

        // Absence of NotSync means this is a sync sample, i.e. a keyframe.
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    // MARK: - Helpers

    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) {
        VTSessionSetProperty(session, key: key, value: value)
    }

    enum EncoderError: Error, LocalizedError {
        case sessionCreationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .sessionCreationFailed(let status):
                return "Could not create H.264 encoder (status \(status))"
            }
        }
    }
}
