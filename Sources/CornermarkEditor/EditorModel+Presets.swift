import Foundation
import CornermarkCore

extension EditorModel {
    var stylePresetsForTool: [StylePreset] { prefs.stylePresets.filter { $0.tool == styleTool.name } }

    func saveStylePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var all = prefs.stylePresets
        all.removeAll { $0.name == trimmed && $0.tool == styleTool.name }
        all.append(StylePreset(name: trimmed, tool: styleTool.name, style: activeStyle))
        prefs.stylePresets = all
        notify(.style)
    }

    func applyStylePreset(_ preset: StylePreset) {
        editStyle({ $0 = preset.style }, key: "preset")
        endCoalescing()
    }

    func deleteStylePreset(_ id: UUID) {
        prefs.stylePresets = prefs.stylePresets.filter { $0.id != id }
        notify(.style)
    }

    func addFavoriteColor(_ color: RGBA) {
        var all = prefs.favoriteColors
        guard !all.contains(where: { $0.isClose(to: color) }) else { return }
        all.append(color)
        prefs.favoriteColors = Array(all.suffix(10))
        notify(.style)
    }

    func removeFavoriteColor(_ color: RGBA) {
        prefs.favoriteColors = prefs.favoriteColors.filter { !$0.isClose(to: color) }
        notify(.style)
    }

    func saveBackgroundPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let style = document.background else { return }
        var all = prefs.backgroundPresets
        all.removeAll { $0.name == trimmed }
        all.append(BackgroundPreset(name: trimmed, style: style))
        prefs.backgroundPresets = all
        notify(.document)
    }

    func applyBackgroundPreset(_ preset: BackgroundPreset) {
        var style = preset.style
        // A preset can outlive the image asset it pointed at.
        if case .image(let asset) = style.fill, !assets.contains(asset) { style.fill = .builtin(index: 0) }
        perform(.setBackground(style))
    }

    func deleteBackgroundPreset(_ id: UUID) {
        prefs.backgroundPresets = prefs.backgroundPresets.filter { $0.id != id }
        notify(.document)
    }
}
