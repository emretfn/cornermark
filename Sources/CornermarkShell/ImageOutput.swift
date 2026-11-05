import AppKit
import CornermarkCore

enum ImageOutput {
    /// PNG for apps that take it, TIFF for the ones that only know NSImage.
    static func copy(_ image: CGImage, to pasteboard: NSPasteboard) -> Bool {
        guard let png = AssetStore.pngData(from: image) else { return false }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        return true
    }

    /// A file reference, which Finder, Mail and chat apps paste as the file itself.
    static func copy(file: URL, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.writeObjects([file as NSURL])
    }

    /// `0:07`, `12:30`, `1:02:03`. Seconds round down, so a video never reads longer than it is.
    static func durationText(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func copy(text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// `Cornermark 2026-11-03 at 14.05.09.png`
    static func fileName(for date: Date, format: SaveFormat) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "'Cornermark' yyyy-MM-dd 'at' HH.mm.ss"
        return "\(f.string(from: date)).\(format.fileExtension)"
    }

    /// Never overwrites: a second capture within the same second gets " 2", " 3", and so on.
    static func uniqueURL(in folder: URL, for date: Date, format: SaveFormat) -> URL {
        let base = fileName(for: date, format: format)
        var url = folder.appendingPathComponent(base)
        var n = 2
        let stem = (base as NSString).deletingPathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) \(n).\(format.fileExtension)")
            n += 1
        }
        return url
    }

    static func encode(_ image: CGImage, format: SaveFormat) throws -> Data {
        try Exporter.data(from: image, format: format == .png ? .png : .jpeg, quality: 0.92)
    }

    @discardableResult
    static func save(_ image: CGImage, format: SaveFormat, folder: URL, date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, for: date, format: format)
        try encode(image, format: format).write(to: url, options: .atomic)
        return url
    }

    static func dimensionText(_ size: CGSize) -> String { "\(Int(size.width)) \u{00D7} \(Int(size.height))" }
}
