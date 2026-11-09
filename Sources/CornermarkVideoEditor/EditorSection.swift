import CornermarkL10n
import Foundation

/// One section of the settings rail, in rail order.
public enum EditorSection: String, CaseIterable, Sendable {
    case cursor, clicks, keystrokes, audio, camera, background, motionBlur

    public var title: String {
        switch self {
        case .cursor: return tr("Cursor")
        case .clicks: return tr("Clicks")
        case .keystrokes: return tr("Keystrokes")
        case .audio: return tr("Audio")
        case .camera: return tr("Camera")
        case .background: return tr("Background")
        case .motionBlur: return tr("Motion Blur")
        }
    }

    public var symbol: String {
        switch self {
        case .cursor: return "cursorarrow"
        case .clicks: return "cursorarrow.click"
        case .keystrokes: return "keyboard"
        case .audio: return "speaker.wave.2"
        case .camera: return "web.camera"
        case .background: return "photo"
        case .motionBlur: return "wind"
        }
    }
}
