import Foundation

public enum ProjectFileError: Error, Equatable {
    case missingAsset(AssetID)
    case invalidAssetID(AssetID)
    case unsupportedVersion(Int)
    case notAProject(URL)
}

/// A directory package: `project.json` plus `assets/<id>.png`. Safe to call on a directory that
/// holds other files (a capture folder keeps its `image.png` beside the project).
public enum ProjectFile {
    public static let documentFileName = "project.json"
    public static let assetsDirectoryName = "assets"
    public static let currentVersion = 1

    private struct Envelope: Codable {
        var version: Int
        var document: Document
    }

    private static func validate(_ id: AssetID) throws {
        let ok = !id.isEmpty && id.count <= 128 && id.first != "."
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) && $0.isASCII }
        guard ok else { throw ProjectFileError.invalidAssetID(id) }
    }

    /// Asset files land first and `project.json` last, each atomically, so a crash leaves either
    /// the previous project or the new one. Assets the document no longer references are removed.
    public static func write(_ doc: Document, assets: AssetStore, to url: URL) throws {
        let fm = FileManager.default
        let referenced = doc.referencedAssets
        for id in referenced { try validate(id) }

        let assetsDir = url.appendingPathComponent(assetsDirectoryName, isDirectory: true)
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        for id in referenced.sorted() {
            guard let data = assets.data(for: id) else { throw ProjectFileError.missingAsset(id) }
            let file = assetsDir.appendingPathComponent("\(id).png")
            if let existing = try? Data(contentsOf: file), existing == data { continue }
            try data.write(to: file, options: .atomic)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(Envelope(version: currentVersion, document: doc))
        try json.write(to: url.appendingPathComponent(documentFileName), options: .atomic)

        let keep = Set(referenced.map { "\($0).png" })
        for name in (try? fm.contentsOfDirectory(atPath: assetsDir.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: assetsDir.appendingPathComponent(name))
        }
    }

    public static func read(from url: URL) throws -> (document: Document, assets: AssetStore) {
        let fm = FileManager.default
        let jsonURL = url.appendingPathComponent(documentFileName)
        guard fm.fileExists(atPath: jsonURL.path) else { throw ProjectFileError.notAProject(url) }

        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: jsonURL))
        guard envelope.version <= currentVersion else { throw ProjectFileError.unsupportedVersion(envelope.version) }

        let store = AssetStore()
        let assetsDir = url.appendingPathComponent(assetsDirectoryName, isDirectory: true)
        for id in envelope.document.referencedAssets.sorted() {
            try validate(id)
            let file = assetsDir.appendingPathComponent("\(id).png")
            guard let data = try? Data(contentsOf: file) else { throw ProjectFileError.missingAsset(id) }
            store.add(png: data, id: id)
        }
        return (envelope.document, store)
    }
}
