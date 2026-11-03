import CoreGraphics
import Foundation
import Vision

struct OCRLine: Equatable {
    var text: String
    /// Vision's normalized box, origin bottom-left.
    var box: CGRect
}

struct OCRResult: Equatable {
    var lines: [OCRLine]
    var qrPayloads: [String]

    var text: String { lines.map(\.text).joined(separator: "\n") }
    var isEmpty: Bool { lines.isEmpty && qrPayloads.isEmpty }

    /// What lands on the clipboard: the recognized text, then any QR payloads, one per line.
    var clipboardText: String {
        ([text].filter { !$0.isEmpty } + qrPayloads).joined(separator: "\n")
    }
}

enum OCRError: Error { case visionFailed(String) }

/// On-device text and QR recognition. Runs Vision off the calling actor.
func recognize(_ image: CGImage) async throws -> OCRResult {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            do { cont.resume(returning: try recognizeSync(image)) } catch { cont.resume(throwing: error) }
        }
    }
}

func recognizeSync(_ image: CGImage) throws -> OCRResult {
    let text = VNRecognizeTextRequest()
    text.recognitionLevel = .accurate
    text.usesLanguageCorrection = true
    text.automaticallyDetectsLanguage = true
    let supported = (try? text.supportedRecognitionLanguages()) ?? []
    let preferred = ["tr-TR", "en-US"].filter { supported.contains($0) }
    if !preferred.isEmpty { text.recognitionLanguages = preferred }

    let barcodes = VNDetectBarcodesRequest()
    barcodes.symbologies = [.qr]

    do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([text, barcodes])
    } catch {
        throw OCRError.visionFailed(error.localizedDescription)
    }

    let found = (text.results ?? []).compactMap { obs -> OCRLine? in
        guard let best = obs.topCandidates(1).first, !best.string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return OCRLine(text: best.string, box: obs.boundingBox)
    }
    let payloads = (barcodes.results ?? [])
        .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        .compactMap(\.payloadStringValue)
    return OCRResult(lines: readingOrder(found), qrPayloads: payloads)
}

/// Top to bottom, then left to right; boxes whose vertical centers are within half a line share a row.
func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
    let byTop = lines.sorted { $0.box.midY > $1.box.midY }
    var rows: [[OCRLine]] = []
    for line in byTop {
        if let last = rows.last?.first, abs(last.box.midY - line.box.midY) < min(last.box.height, line.box.height) * 0.5 {
            rows[rows.count - 1].append(line)
        } else {
            rows.append([line])
        }
    }
    return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
}
