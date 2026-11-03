import CoreGraphics
import Foundation

/// Builds one tall (or wide) image from successive frames of a scrolling view.
///
/// Internally everything is "lines along the scroll axis": rows for vertical scrolling, columns
/// for horizontal (frames are transposed on the way in and out), so there is one matcher.
public struct ScrollStitcher {
    public enum Axis: Sendable { case vertical, horizontal }

    public struct Options: Sendable {
        public var axis: Axis = .vertical
        /// Lines pinned at the start (header or left rail) and end (footer or right rail) of every
        /// frame. nil detects them as the lines that are identical between consecutive frames.
        public var stickyStart: Int? = nil
        public var stickyEnd: Int? = nil
        /// Upper bound for auto-detected sticky regions, per side, as a fraction of the frame.
        public var maxStickyFraction = 0.4
        /// Fewest overlapping lines a match may rest on, capped at a quarter of the scrolling area.
        public var minOverlap = 24
        /// Share of overlapping lines allowed to differ (cursor blink, tiny animations).
        public var mismatchTolerance = 0.01
        public init() {}
    }

    public enum Outcome: Equatable, Sendable {
        case started
        case appended(lines: Int)
        case noMovement
        /// The view moved back toward content already captured. Ignored, and the reference
        /// frame stays at the furthest point so scrolling forward again resumes cleanly.
        case scrolledBackward
        /// No offset explains the frame. Ignored; scroll less between frames.
        case noOverlap
        case sizeMismatch
        case unreadable
    }

    private struct Lines {
        var bytes: [UInt8]
        var count: Int
        var lineBytes: Int
        var hashes: [UInt64]
        /// False for single-color lines. Matches made only of those say nothing about the offset.
        var informative: [Bool]

        init(buffer: PixelBuffer, axis: Axis) {
            switch axis {
            case .vertical:
                bytes = buffer.bytes
                count = buffer.height
                lineBytes = buffer.width * 4
            case .horizontal:
                let w = buffer.width, h = buffer.height
                var t = [UInt8](repeating: 0, count: w * h * 4)
                buffer.bytes.withUnsafeBufferPointer { src in
                    t.withUnsafeMutableBufferPointer { dst in
                        for y in 0..<h {
                            for x in 0..<w {
                                let s = (y * w + x) * 4, d = (x * h + y) * 4
                                dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]; dst[d + 3] = src[s + 3]
                            }
                        }
                    }
                }
                bytes = t
                count = w
                lineBytes = h * 4
            }
            hashes = []
            informative = []
            hashes = (0..<count).map { Self.hash(bytes, $0 * lineBytes, lineBytes) }
            informative = (0..<count).map { Self.isVaried(bytes, $0 * lineBytes, lineBytes) }
        }

        static func isVaried(_ bytes: [UInt8], _ start: Int, _ length: Int) -> Bool {
            bytes.withUnsafeBufferPointer { p in
                var i = start + 4
                while i < start + length {
                    if (p[i] & 0xFC) != (p[i - 4] & 0xFC) || (p[i + 1] & 0xFC) != (p[i - 3] & 0xFC) || (p[i + 2] & 0xFC) != (p[i - 2] & 0xFC) { return true }
                    i += 4
                }
                return false
            }
        }

        /// FNV-1a over the top six bits of each channel, so compression noise does not break equality.
        static func hash(_ bytes: [UInt8], _ start: Int, _ length: Int) -> UInt64 {
            var h: UInt64 = 0xCBF2_9CE4_8422_2325
            bytes.withUnsafeBufferPointer { p in
                for i in start..<(start + length) {
                    h = (h ^ UInt64(p[i] & 0xFC)) &* 0x0000_0100_0000_01B3
                }
            }
            return h
        }
    }

    public let options: Options
    private var data: [UInt8] = []
    private var lineBytes = 0
    private var previous: Lines?
    /// Sticky sizes are measured once, on the first pair of frames that matches, and then kept:
    /// re-measuring per pair would let coincidentally blank lines change what counts as footer.
    private var lockedSticky: (top: Int, bottom: Int)?
    /// Last accepted frame's trailing sticky lines. Held apart from `data` so the footer appears once, at the end.
    private var footer: [UInt8] = []

    public init(options: Options = Options()) { self.options = options }

    /// Lines accumulated so far along the scroll axis.
    public var lineCount: Int { lineBytes == 0 ? 0 : (data.count + footer.count) / lineBytes }

    @discardableResult
    public mutating func add(_ frame: CGImage) -> Outcome {
        guard let buffer = PixelBuffer(image: frame) else { return .unreadable }
        let cur = Lines(buffer: buffer, axis: options.axis)

        guard let prev = previous else {
            data = cur.bytes
            lineBytes = cur.lineBytes
            previous = cur
            return .started
        }
        guard prev.count == cur.count, prev.lineBytes == cur.lineBytes else { return .sizeMismatch }
        if prev.hashes == cur.hashes { return .noMovement }

        let n = cur.count
        let cap = Int(Double(n) * min(max(options.maxStickyFraction, 0), 0.49))

        // Candidate sticky sizes, tried in order. Detected regions are first trimmed back to their
        // last varied line, because blank page margin that merely sits next to a header is not
        // part of it and would hide content that later scrolls into that margin. The untrimmed
        // size is the fallback for headers that really end in padding.
        var candidates: [(top: Int, bottom: Int)]
        if let locked = lockedSticky {
            candidates = [locked]
        } else {
            let top = min(options.stickyStart ?? commonPrefix(prev.hashes, cur.hashes), cap)
            let bottom = min(options.stickyEnd ?? commonSuffix(prev.hashes, cur.hashes), cap)
            candidates = [(top, bottom)]
            var t = options.stickyStart == nil ? top : 0, b = options.stickyEnd == nil ? bottom : 0
            while t > 0, !cur.informative[t - 1] { t -= 1 }
            while b > 0, !cur.informative[n - b] { b -= 1 }
            let trimmed = (options.stickyStart == nil ? t : top, options.stickyEnd == nil ? b : bottom)
            if trimmed != (top, bottom) { candidates.insert(trimmed, at: 0) }
        }

        var found: (shift: Int, top: Int, bottom: Int)?
        var sawBackward = false, sawStill = false
        for c in candidates {
            guard let shift = bestShift(prev, cur, top: c.top, bottom: c.bottom) else { continue }
            if shift > 0 { found = (shift, c.top, c.bottom); break }
            if shift < 0 { sawBackward = true } else { sawStill = true }
        }

        guard let match = found else {
            if sawBackward { return .scrolledBackward }
            return sawStill ? .noMovement : .noOverlap
        }

        let bodyEnd = n - match.bottom
        if lockedSticky == nil {
            lockedSticky = (match.top, match.bottom)
            // The first frame's own tail was stored as ordinary lines; it is the footer.
            data.removeLast(min(match.bottom, lineCount) * lineBytes)
        }
        data.append(contentsOf: cur.bytes[((bodyEnd - match.shift) * lineBytes)..<(bodyEnd * lineBytes)])
        footer = Array(cur.bytes[(bodyEnd * lineBytes)..<(n * lineBytes)])
        previous = cur
        return .appended(lines: match.shift)
    }

    /// Offset of `cur` relative to `prev` over the scrolling area between the sticky regions, or
    /// nil if no offset explains it. Positive means the view moved forward.
    private func bestShift(_ prev: Lines, _ cur: Lines, top: Int, bottom: Int) -> Int? {
        let bodyStart = top, bodyN = cur.count - bottom - top
        guard bodyN >= 8 else { return nil }
        let minOverlap = max(4, min(options.minOverlap, bodyN / 4))

        // Ranked by how many distinct (non-blank) lines agree, so an offset that merely lines up
        // blank margins with blank margins cannot beat the real one; then fewer mismatches, then
        // the smaller move.
        var best: (shift: Int, mismatches: Int, evidence: Int)?
        for shift in -(bodyN - minOverlap)...(bodyN - minOverlap) {
            let overlap = bodyN - abs(shift)
            let allowed = Int(Double(overlap) * options.mismatchTolerance)
            // For shift > 0 the frame moved down: cur[r] == prev[r + shift].
            let pOff = bodyStart + (shift > 0 ? shift : 0), cOff = bodyStart + (shift < 0 ? -shift : 0)
            var bad = 0, evidence = 0
            var r = 0
            while r < overlap {
                if prev.hashes[pOff + r] != cur.hashes[cOff + r] {
                    bad += 1
                    if bad > allowed { break }
                } else if cur.informative[cOff + r] {
                    evidence += 1
                }
                r += 1
            }
            guard r == overlap else { continue }
            if let b = best {
                let better = evidence > b.evidence
                    || (evidence == b.evidence && (bad < b.mismatches || (bad == b.mismatches && abs(shift) < abs(b.shift))))
                if better { best = (shift, bad, evidence) }
            } else {
                best = (shift, bad, evidence)
            }
        }
        return best?.shift
    }

    /// The stitched image so far, nil before the first frame.
    public var image: CGImage? {
        guard lineBytes > 0, !data.isEmpty else { return nil }
        let count = lineCount
        let data = self.data + footer
        switch options.axis {
        case .vertical:
            return PixelBuffer(width: lineBytes / 4, height: count, bytes: data).makeImage()
        case .horizontal:
            let h = lineBytes / 4, w = count
            var out = [UInt8](repeating: 0, count: w * h * 4)
            data.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for x in 0..<w {
                        for y in 0..<h {
                            let s = (x * h + y) * 4, d = (y * w + x) * 4
                            dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]; dst[d + 3] = src[s + 3]
                        }
                    }
                }
            }
            return PixelBuffer(width: w, height: h, bytes: out).makeImage()
        }
    }

    private func commonPrefix(_ a: [UInt64], _ b: [UInt64]) -> Int {
        var i = 0
        while i < a.count, a[i] == b[i] { i += 1 }
        return i
    }

    private func commonSuffix(_ a: [UInt64], _ b: [UInt64]) -> Int {
        var i = 0
        while i < a.count, a[a.count - 1 - i] == b[b.count - 1 - i] { i += 1 }
        return i
    }
}
