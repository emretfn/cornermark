import CoreGraphics
import Foundation

/// A cell of a 3×3 grid laid over the picture: where a camera bubble or a keystroke badge sits. Cases run row by row from the top left,
/// the order a position picker lays them out.
public enum GridPosition: String, Codable, CaseIterable, Sendable {
    case topLeft, topCenter, topRight
    case middleLeft, center, middleRight
    case bottomLeft, bottomCenter, bottomRight

    public static let corners: [GridPosition] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    /// 0 on the left, 2 on the right.
    public var column: Int { Self.allCases.firstIndex(of: self)! % 3 }
    /// 0 at the top, 2 at the bottom.
    public var row: Int { Self.allCases.firstIndex(of: self)! / 3 }

    public init(column: Int, row: Int) {
        self = Self.allCases[min(max(row, 0), 2) * 3 + min(max(column, 0), 2)]
    }

    public var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topCenter: return "Top center"
        case .topRight: return "Top right"
        case .middleLeft: return "Middle left"
        case .center: return "Center"
        case .middleRight: return "Middle right"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        }
    }

    /// A box of `size` in this cell of `area`, `margin` in from each edge it sits against and centred on the axes it does not.
    /// Points with the origin at the area's top-left corner, y down.
    public func place(_ size: CGSize, in area: CGSize, margin: Double) -> CGRect {
        func offset(_ index: Int, _ length: Double, _ room: Double) -> Double {
            switch index {
            case 0: return margin
            case 1: return ((room - length) / 2).rounded()
            default: return room - margin - length
            }
        }
        return CGRect(x: offset(column, size.width, area.width), y: offset(row, size.height, area.height), width: size.width, height: size.height)
    }

    /// The corner nearest `point`, in the area's points with y down.
    public static func corner(nearest point: CGPoint, area: CGSize) -> GridPosition {
        GridPosition(column: point.x < area.width / 2 ? 0 : 2, row: point.y < area.height / 2 ? 0 : 2)
    }
}
