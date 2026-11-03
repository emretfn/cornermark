import Foundation
import KadrajCore

/// Everything a tool remembers between uses. One struct for all tools: a tool simply ignores
/// the fields its `ToolSpec.properties` does not list.
struct ToolStyle: Codable, Equatable {
    var color: RGBA
    var width: Double
    var arrowStyle: ArrowStyle = .classic
    var textStyle: TextStylePreset = .bold
    var fontSize: Double = 32
    var blurMode: BlurMode = .smooth
    var pixelBlock: Int = 12

    var stroke: Stroke { Stroke(color: color, width: width) }
}

enum PropertyKind: Hashable {
    case color, width, arrowStyle, textStyle, fontSize, blurMode, pixelBlock
}

struct StylePreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var tool: String
    var style: ToolStyle
}

struct BackgroundPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var style: BackgroundStyle
}

enum Palette {
    static let swatches: [RGBA] = [
        RGBA(hex: 0xE5303A), RGBA(hex: 0xF28C28), RGBA(hex: 0xF7D117), RGBA(hex: 0x2FBF5B),
        RGBA(hex: 0x1E88F0), RGBA(hex: 0x8E4EC6), RGBA(hex: 0x111111), RGBA(hex: 0xFFFFFF),
    ]
    static let red = swatches[0]
    static let yellow = swatches[2]
}

/// Favourite colours and saved presets, persisted as JSON blobs in UserDefaults.
final class EditorPreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }

    private func load<T: Decodable>(_ key: String, as _: T.Type) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    var favoriteColors: [RGBA] {
        get { load("kadraj.palette.favorites", as: [RGBA].self) ?? [] }
        set { store(newValue, "kadraj.palette.favorites") }
    }
    var stylePresets: [StylePreset] {
        get { load("kadraj.presets.style", as: [StylePreset].self) ?? [] }
        set { store(newValue, "kadraj.presets.style") }
    }
    var backgroundPresets: [BackgroundPreset] {
        get { load("kadraj.presets.background", as: [BackgroundPreset].self) ?? [] }
        set { store(newValue, "kadraj.presets.background") }
    }
}
