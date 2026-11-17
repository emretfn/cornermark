import Foundation

/// A biquad filter in direct form I, run in doubles, keeping its history from one call to the next. Low cut and the loudness meter's
/// K-weighting are made of them.
struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    /// A high-pass at `frequency` with quality `q`, from Robert Bristow-Johnson's Audio EQ Cookbook.
    static func highPass(_ frequency: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * min(frequency, rate * 0.45) / rate
        let alpha = sin(w) / (2 * q), cosw = cos(w), a0 = 1 + alpha
        let b0 = (1 + cosw) / 2 / a0
        return Biquad(b0: b0, b1: -(1 + cosw) / a0, b2: b0, a1: -2 * cosw / a0, a2: (1 - alpha) / a0)
    }

    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    /// Filters `count` samples in place.
    mutating func run(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count { samples[i] = Float(run(Double(samples[i]))) }
    }
}
