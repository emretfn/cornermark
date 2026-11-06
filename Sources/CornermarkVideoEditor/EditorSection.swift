import Foundation

/// One section of the settings rail, in rail order.
public enum EditorSection: String, CaseIterable, Sendable {
    case cursor, clicks, keystrokes, audio, camera, background, motionBlur

    public var title: String {
        switch self {
        case .cursor: return "Cursor"
        case .clicks: return "Clicks"
        case .keystrokes: return "Keystrokes"
        case .audio: return "Audio"
        case .camera: return "Camera"
        case .background: return "Background"
        case .motionBlur: return "Motion Blur"
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
