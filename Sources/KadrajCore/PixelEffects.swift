import CoreGraphics
import Foundation

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Redaction effects that read and rewrite the pixels already composited into a bitmap context.
/// Everything is plain integer/float math on the buffer so results are identical across machines.
enum PixelEffects {
    struct Region {
        var x: Int, y: Int, width: Int, height: Int
    }

    private static func region(_ rect: CGRect, in ctx: CGContext) -> Region? {
        let bounds = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        let r = rect.integralClamped(to: bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        return Region(x: Int(r.minX), y: Int(r.minY), width: Int(r.width), height: Int(r.height))
    }

    private static func read(_ reg: Region, from ctx: CGContext) -> [UInt8]? {
        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        var out = [UInt8](repeating: 0, count: reg.width * reg.height * 4)
        out.withUnsafeMutableBytes { dst in
            for row in 0..<reg.height {
                memcpy(dst.baseAddress! + row * reg.width * 4, data + (reg.y + row) * bpr + reg.x * 4, reg.width * 4)
            }
        }
        return out
    }

    private static func write(_ pixels: [UInt8], _ reg: Region, to ctx: CGContext) {
        guard let data = ctx.data else { return }
        let bpr = ctx.bytesPerRow
        pixels.withUnsafeBytes { src in
            for row in 0..<reg.height {
                memcpy(data + (reg.y + row) * bpr + reg.x * 4, src.baseAddress! + row * reg.width * 4, reg.width * 4)
            }
        }
    }

    // MARK: Blur

    static func blur(_ rect: CGRect, mode: BlurMode, in ctx: CGContext) {
        guard let reg = region(rect, in: ctx), var px = read(reg, from: ctx) else { return }
        let short = Double(min(reg.width, reg.height))
        switch mode {
        case .smooth:
            gaussian(&px, reg.width, reg.height, sigma: min(max(short * 0.12, 6), 28))
        case .secure:
            // One sample per block per channel survives, so no sharpening of the output can bring
            // back what the block averages already dropped.
            let block = max(10, Int(short / 4))
            px = coarseUpsample(px, reg.width, reg.height, block: block)
            gaussian(&px, reg.width, reg.height, sigma: Double(block) * 0.3)
        }
        write(px, reg, to: ctx)
    }

    static func gaussian(_ px: inout [UInt8], _ w: Int, _ h: Int, sigma: Double) {
        var scratch = px
        for radius in boxRadii(sigma: sigma, passes: 3) where radius > 0 {
            boxPass(px, &scratch, w, h, radius: radius, horizontal: true)
            boxPass(scratch, &px, w, h, radius: radius, horizontal: false)
        }
    }

    private static func boxRadii(sigma: Double, passes n: Int) -> [Int] {
        let nd = Double(n)
        let ideal = (12 * sigma * sigma / nd + 1).squareRoot()
        var wl = Int(ideal.rounded(.down))
        if wl % 2 == 0 { wl -= 1 }
        wl = max(wl, 1)
        let wu = wl + 2
        let m = Int(((12 * sigma * sigma - nd * Double(wl * wl) - 4 * nd * Double(wl) - 3 * nd) / (-4 * Double(wl) - 4)).rounded())
        return (0..<n).map { (($0 < m ? wl : wu) - 1) / 2 }
    }

    private static func boxPass(_ src: [UInt8], _ dst: inout [UInt8], _ w: Int, _ h: Int, radius r: Int, horizontal: Bool) {
        let lines = horizontal ? h : w
        let n = horizontal ? w : h
        let step = horizontal ? 4 : w * 4
        let lineStep = horizontal ? w * 4 : 4
        let window = 2 * r + 1
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                for line in 0..<lines {
                    let base = line * lineStep
                    for c in 0..<4 {
                        func at(_ i: Int) -> Int { Int(s[base + min(max(i, 0), n - 1) * step + c]) }
                        var sum = 0
                        for j in -r...r { sum += at(j) }
                        for i in 0..<n {
                            d[base + i * step + c] = UInt8((sum + window / 2) / window)
                            sum += at(i + r + 1) - at(i - r)
                        }
                    }
                }
            }
        }
    }

    private static func coarseUpsample(_ px: [UInt8], _ w: Int, _ h: Int, block: Int) -> [UInt8] {
        let gw = (w + block - 1) / block, gh = (h + block - 1) / block
        var grid = [Float](repeating: 0, count: gw * gh * 4)
        for gy in 0..<gh {
            for gx in 0..<gw {
                var sum = [Int](repeating: 0, count: 4)
                var count = 0
                for y in (gy * block)..<min((gy + 1) * block, h) {
                    for x in (gx * block)..<min((gx + 1) * block, w) {
                        let i = (y * w + x) * 4
                        for c in 0..<4 { sum[c] += Int(px[i + c]) }
                        count += 1
                    }
                }
                for c in 0..<4 { grid[(gy * gw + gx) * 4 + c] = Float(sum[c]) / Float(count) }
            }
        }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let inv = 1 / Float(block)
        for y in 0..<h {
            let fy = (Float(y) + 0.5) * inv - 0.5
            let y0 = min(max(Int(fy.rounded(.down)), 0), gh - 1), y1 = min(y0 + 1, gh - 1)
            let ty = min(max(fy - Float(y0), 0), 1)
            for x in 0..<w {
                let fx = (Float(x) + 0.5) * inv - 0.5
                let x0 = min(max(Int(fx.rounded(.down)), 0), gw - 1), x1 = min(x0 + 1, gw - 1)
                let tx = min(max(fx - Float(x0), 0), 1)
                for c in 0..<4 {
                    let a = grid[(y0 * gw + x0) * 4 + c], b = grid[(y0 * gw + x1) * 4 + c]
                    let d = grid[(y1 * gw + x0) * 4 + c], e = grid[(y1 * gw + x1) * 4 + c]
                    let v = (a + (b - a) * tx) + ((d + (e - d) * tx) - (a + (b - a) * tx)) * ty
                    out[(y * w + x) * 4 + c] = UInt8(min(max(v.rounded(), 0), 255))
                }
            }
        }
        return out
    }

    // MARK: Pixelate

    /// Block averages with a deterministic per-block brightness jitter derived from `seed`.
    /// Plain block averaging can be matched against rendered guesses of the hidden text; the jitter
    /// makes each block's value depend on a secret the viewer does not have.
    static func pixelate(_ rect: CGRect, blockSize: Int, seed: UInt64, in ctx: CGContext) {
        guard let reg = region(rect, in: ctx), var px = read(reg, from: ctx) else { return }
        let block = max(blockSize, 2)
        let w = reg.width, h = reg.height

        for by in stride(from: 0, to: h, by: block) {
            for bx in stride(from: 0, to: w, by: block) {
                let x1 = min(bx + block, w), y1 = min(by + block, h)
                var sum = [Int](repeating: 0, count: 4)
                for y in by..<y1 {
                    for x in bx..<x1 {
                        let i = (y * w + x) * 4
                        for c in 0..<4 { sum[c] += Int(px[i + c]) }
                    }
                }
                let count = (x1 - bx) * (y1 - by)
                var avg = sum.map { ($0 + count / 2) / count }

                // Keyed on grid position relative to the region so moving the annotation keeps its look.
                let gx = UInt64(bx / block), gy = UInt64(by / block)
                var rng = SplitMix64(state: seed ^ (gx &* 0x9E37_79B9_7F4A_7C15) ^ (gy &* 0xC2B2_AE3D_27D4_EB4F))
                _ = rng.next()
                let shift = Int(rng.next() % 21) - 10
                for c in 0..<3 {
                    let chroma = Int(rng.next() % 5) - 2
                    avg[c] = min(max(avg[c] + shift + chroma, 0), avg[3])
                }
                for y in by..<y1 {
                    for x in bx..<x1 {
                        let i = (y * w + x) * 4
                        for c in 0..<4 { px[i + c] = UInt8(avg[c]) }
                    }
                }
            }
        }
        write(px, reg, to: ctx)
    }
}
