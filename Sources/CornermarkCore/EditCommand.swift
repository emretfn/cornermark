import CoreGraphics
import Foundation

extension Document {
    public var sourceBounds: CGRect { CGRect(origin: .zero, size: pixelSize) }

    /// Assets this document needs to render: base image, image annotations, image background.
    public var referencedAssets: Set<AssetID> {
        var ids: Set<AssetID> = [base]
        for a in annotations {
            if case .image(_, let asset) = a.kind { ids.insert(asset) }
        }
        if case .image(let asset)? = background?.fill { ids.insert(asset) }
        return ids
    }

    /// The reducer. Pure; commands that cannot apply (unknown id, degenerate crop, non-finite scale)
    /// return the document unchanged so history never records them.
    public func applying(_ command: EditCommand) -> Document {
        var doc = self
        switch command {
        case .add(let annotation):
            if let i = doc.annotations.firstIndex(where: { $0.id == annotation.id }) {
                doc.annotations[i] = annotation
            } else {
                doc.annotations.append(annotation)
            }

        case .update(let annotation):
            guard let i = doc.annotations.firstIndex(where: { $0.id == annotation.id }) else { return self }
            doc.annotations[i] = annotation

        case .remove(let id):
            doc.annotations.removeAll { $0.id == id }

        case .reorder(let id, let toIndex):
            guard let from = doc.annotations.firstIndex(where: { $0.id == id }) else { return self }
            let item = doc.annotations.remove(at: from)
            doc.annotations.insert(item, at: min(max(toIndex, 0), doc.annotations.count))

        case .setCrop(let rect):
            guard let rect else { doc.crop = nil; break }
            guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return self }
            let clamped = rect.integralClamped(to: sourceBounds)
            guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return self }
            doc.crop = clamped == sourceBounds ? nil : clamped

        // Geometry is "flips first, then clockwise turns". An on-screen mirror of the current
        // result is F·R(q)·F0 = R(-q)·F·F0, so a flip also negates the turn count.
        case .rotateClockwise:
            doc.geometry.quarterTurns = (doc.geometry.quarterTurns + 1) & 3
        case .flipHorizontal:
            doc.geometry.flipH.toggle()
            doc.geometry.quarterTurns = (4 - doc.geometry.quarterTurns) & 3
        case .flipVertical:
            doc.geometry.flipV.toggle()
            doc.geometry.quarterTurns = (4 - doc.geometry.quarterTurns) & 3

        case .setOutputScale(let scale):
            guard scale.isFinite, scale > 0 else { return self }
            doc.outputScale = min(max(scale, Document.outputScaleRange.lowerBound), Document.outputScaleRange.upperBound)

        case .setBackground(let style):
            doc.background = style
        }
        return doc
    }

    public static let outputScaleRange: ClosedRange<Double> = 0.05...8
}

/// Groups consecutive commands into one undo step, e.g. every tick of a slider drag.
public struct CoalescingKey: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct EditHistory: Sendable {
    public private(set) var past: [Document] = []
    public private(set) var present: Document
    public private(set) var future: [Document] = []
    public let limit: Int
    private var openGroup: CoalescingKey?

    public init(_ document: Document, limit: Int = 200) {
        present = document
        self.limit = max(1, limit)
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    /// With a `coalescing` key equal to the previous apply's key, the command folds into the
    /// open undo step instead of starting a new one. Any other apply, undo or redo closes the group.
    public mutating func apply(_ command: EditCommand, coalescing key: CoalescingKey? = nil) {
        let next = present.applying(command)
        guard next != present else { return }

        if let key, key == openGroup, !past.isEmpty {
            present = next
            if present == past.last {
                past.removeLast()
                openGroup = nil
            }
            return
        }

        past.append(present)
        if past.count > limit { past.removeFirst(past.count - limit) }
        present = next
        future.removeAll()
        openGroup = key
    }

    public mutating func endCoalescing() { openGroup = nil }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = past.popLast() else { return false }
        future.append(present)
        present = previous
        openGroup = nil
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = future.popLast() else { return false }
        past.append(present)
        present = next
        openGroup = nil
        return true
    }
}
