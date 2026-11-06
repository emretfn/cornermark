import CoreGraphics
import Foundation
import Metal

/// Memory a Metal buffer can wrap without copying: page aligned and a whole number of pages long. A bitmap drawn into it by the CPU
/// is then the very bytes the GPU reads, and the other way round, on a Mac whose GPU shares the memory.
final class SharedPixels {
    let pointer: UnsafeMutableRawPointer
    let length: Int
    let buffer: MTLBuffer

    init?(device: MTLDevice, bytes: Int) {
        let page = Int(getpagesize())
        let rounded = (max(bytes, 1) + page - 1) / page * page
        var raw: UnsafeMutableRawPointer?
        guard posix_memalign(&raw, page, rounded) == 0, let raw else { return nil }
        memset(raw, 0, rounded)
        guard let buffer = device.makeBuffer(bytesNoCopy: raw, length: rounded, options: .storageModeShared, deallocator: nil) else { free(raw); return nil }
        pointer = raw; length = rounded; self.buffer = buffer
    }

    deinit { free(pointer) }
}

/// Averages several placements of one picture on the GPU, the way the drawings of a motion-blurred frame are averaged: every pixel of the
/// result is the mean of the picture sampled, bilinearly, at each placement. One pass does what takes a drawing per placement on the CPU.
final class SampleAverager {
    /// Nil where there is no Metal device, and when `CORNERMARK_EXPORT_CPU` is set, which keeps an export on the processor.
    static let shared: SampleAverager? = ProcessInfo.processInfo.environment["CORNERMARK_EXPORT_CPU"] == nil ? SampleAverager() : nil

    /// Where the picture lands in the result's pixels: the rectangle of the whole picture, y up, in the bitmap the result belongs to.
    struct Placement {
        var minX: Float, maxY: Float, width: Float, height: Float
    }

    private struct Parameters {
        var count: UInt32
        var originX: Float
        var originY: Float
        var width: UInt32
        var height: UInt32
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let alignment: Int

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil), let function = library.makeFunction(name: "averagePlacements"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.device = device; self.queue = queue; self.pipeline = pipeline
        alignment = max(16, device.minimumLinearTextureAlignment(for: .bgra8Unorm))
    }

    /// The row length a picture of `width` pixels needs for a texture over its bytes.
    func rowBytes(width: Int) -> Int { (width * 4 + alignment - 1) / alignment * alignment }

    func texture(over pixels: SharedPixels, width: Int, height: Int, rowBytes: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        return pixels.buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: rowBytes)
    }

    /// Writes into `result`, `width` by `height` pixels packed row after row in the order a bitmap keeps them, the mean of `picture` at each
    /// of `placements`. `origin` is the position, y up, of the result's top-left corner in the same bitmap the placements are in.
    func average(picture: MTLTexture, placements: [Placement], origin: CGPoint, result: SharedPixels, width: Int, height: Int) -> Bool {
        guard !placements.isEmpty, width * height * 4 <= result.length, let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { return false }
        var parameters = Parameters(count: UInt32(placements.count), originX: Float(origin.x), originY: Float(origin.y), width: UInt32(width), height: UInt32(height))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(picture, index: 0)
        encoder.setBuffer(result.buffer, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 1)
        placements.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: group)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return commands.status == .completed
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Parameters { uint count; float originX; float originY; uint width; uint height; };
    struct Placement { float minX; float maxY; float width; float height; };

    kernel void averagePlacements(texture2d<float, access::sample> picture [[texture(0)]],
                                  device uchar4 *result [[buffer(0)]],
                                  constant Parameters &p [[buffer(1)]],
                                  constant Placement *placements [[buffer(2)]],
                                  uint2 id [[thread_position_in_grid]]) {
        if (id.x >= p.width || id.y >= p.height) return;
        constexpr sampler bilinear(coord::normalized, address::clamp_to_edge, filter::linear);
        float x = p.originX + float(id.x) + 0.5;
        float y = p.originY - (float(id.y) + 0.5);
        float4 sum = float4(0);
        for (uint i = 0; i < p.count; i++) {
            Placement q = placements[i];
            sum += picture.sample(bilinear, float2((x - q.minX) / q.width, (q.maxY - y) / q.height));
        }
        float4 mean = clamp(sum / float(p.count) * 255.0 + 0.5, 0.0, 255.0);
        result[id.y * p.width + id.x] = uchar4(mean).bgra;
    }
    """
}
