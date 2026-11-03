import AppKit

public enum ComponentSize: CaseIterable {
    case small, regular, large

    var height: CGFloat {
        switch self {
        case .small: return DS.Size.controlSmall
        case .regular: return DS.Size.control
        case .large: return DS.Size.controlLarge
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .small: return DS.Size.iconSmall
        case .regular: return DS.Size.icon
        case .large: return DS.Size.iconLarge
        }
    }
}
