import CoreVideo
import Foundation
import Metal

/// Runs the temporal denoise shader over captured frames before encoding.
///
/// Deliberately placed ahead of the encoder rather than after decode on the
/// PC: noise is incompressible, so an encoder fed noisy frames spends bits
/// reproducing randomness. Removing it first yields a cleaner picture *and*
/// redirects those bits to real detail.
///
/// Works on NV12 in place of a colour conversion: the two planes are denoised
/// separately, so the buffer handed to VideoToolbox stays in the pixel format
/// the hardware encoder wants.
final class TemporalDenoiser {

    struct Parameters {
        var strength: Float = 0.6
        var threshold: Float = 0.02
        var knee: Float = 0.05
    }

    /// Settings are written from the UI and read on the capture queue, so
    /// they live behind a lock rather than as plain properties.
    private let settingsLock = NSLock()
    private var _enabled = false
    private var _parameters = Parameters()

    func configure(enabled: Bool, strength: Float) {
        settingsLock.lock()
        _enabled = enabled
        _parameters.strength = min(max(strength, 0), 0.95)
        settingsLock.unlock()
    }

    private var snapshot: (enabled: Bool, parameters: Parameters) {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return (_enabled, _parameters)
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// Previous *output*, not previous input — feeding the filtered result
    /// back is what makes this an IIR filter, so noise keeps decaying across
    /// many frames instead of being averaged over just two.
    private var previous: CVPixelBuffer?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "temporalDenoise"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard textureCache != nil else { return nil }
    }

    /// Drops history. Call when the format changes, so a stale frame of a
    /// different size is never blended into a new one.
    func reset() {
        previous = nil
        pool = nil
        poolWidth = 0
        poolHeight = 0
    }

    /// Returns a denoised copy, or the input unchanged if anything is
    /// unavailable — the stream must never fail because a filter did.
    func process(_ input: CVPixelBuffer) -> CVPixelBuffer {
        let (enabled, parameters) = snapshot
        guard enabled else {
            // Drop history while bypassed, so re-enabling cannot blend in a
            // frame from minutes ago.
            previous = nil
            return input
        }

        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)

        guard let pool = pool(for: width, height: height),
              let output = makeBuffer(from: pool) else { return input }

        // The first frame has no history; seed it and pass through.
        guard let previous else {
            self.previous = input
            return input
        }

        guard let commands = queue.makeCommandBuffer() else { return input }

        let planeCount = CVPixelBufferGetPlaneCount(input)
        for plane in 0..<planeCount {
            // Luma is single-channel, chroma is interleaved Cb/Cr at half
            // resolution — hence the per-plane format.
            let format: MTLPixelFormat = plane == 0 ? .r8Unorm : .rg8Unorm

            guard let cur = texture(from: input, plane: plane, format: format),
                  let prev = texture(from: previous, plane: plane, format: format),
                  let out = texture(from: output, plane: plane, format: format),
                  let encoder = commands.makeComputeCommandEncoder()
            else { continue }

            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(cur, index: 0)
            encoder.setTexture(prev, index: 1)
            encoder.setTexture(out, index: 2)

            var params = parameters
            encoder.setBytes(&params, length: MemoryLayout<Parameters>.size, index: 0)

            let w = pipeline.threadExecutionWidth
            let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
            let threadgroup = MTLSize(width: w, height: h, depth: 1)
            let grid = MTLSize(width: cur.width, height: cur.height, depth: 1)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: threadgroup)
            encoder.endEncoding()
        }

        commands.commit()
        // The encoder reads this buffer immediately, so the GPU must be done
        // with it. At 4K30 the kernel is a fraction of the frame budget.
        commands.waitUntilCompleted()

        self.previous = output
        return output
    }

    // MARK: - Resources

    private func pool(for width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool, poolWidth == width, poolHeight == height { return pool }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]

        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                      attributes as CFDictionary,
                                      &created) == kCVReturnSuccess else { return nil }

        pool = created
        poolWidth = width
        poolHeight = height
        previous = nil // history belongs to the old geometry
        return created
    }

    private func makeBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool,
                                                 &buffer) == kCVReturnSuccess
        else { return nil }
        return buffer
    }

    private func texture(from buffer: CVPixelBuffer,
                         plane: Int,
                         format: MTLPixelFormat) -> MTLTexture? {
        guard let textureCache else { return nil }

        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)

        var wrapper: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil,
            format, width, height, plane, &wrapper) == kCVReturnSuccess,
            let wrapper else { return nil }

        return CVMetalTextureGetTexture(wrapper)
    }
}
