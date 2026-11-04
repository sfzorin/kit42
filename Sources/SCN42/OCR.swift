import CoreGraphics
import CoreText
import Foundation
import Vision

/// One recognised line: text and its box in normalised image coordinates (origin bottom-left, as Vision).
struct TextLine: Codable {
    var text: String
    var box: CGRect
}

/// Text recognition with Vision (adapted from PDF42's searchable-PDF OCR).
enum OCR {
    /// Russian, English and Turkish first, then the user's preferred languages Vision knows.
    static let languages: [String] = {
        var wanted = ["ru-RU", "en-US", "tr-TR"]
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? wanted
        for code in Locale.preferredLanguages {
            let base = code.split(separator: "-").first.map(String.init) ?? code
            if let match = supported.first(where: { $0 == code || $0.hasPrefix(base + "-") || $0 == base }), !wanted.contains(match) {
                wanted.append(match)
            }
        }
        return wanted.filter { supported.contains($0) }
    }()

    static func recognize(_ image: CGImage) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { o in
            guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return TextLine(text: s, box: o.boundingBox)
        }
    }

    /// Lines top to bottom as plain text.
    static func text(_ lines: [TextLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// First line that looks like a title (for file names): at least 3 letters, trimmed to 60 characters.
    static func title(_ lines: [TextLine]) -> String? {
        let sorted = lines.sorted { $0.box.maxY > $1.box.maxY }
        guard let line = sorted.first(where: { $0.text.filter(\.isLetter).count >= 3 }) else { return nil }
        let cleaned = line.text.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    /// Invisible (searchable, selectable) text over the recognised lines; `box` is the page area the image covers.
    static func drawInvisibleText(_ lines: [TextLine], box: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let b = line.box
            let r = CGRect(x: box.minX + b.minX * box.width, y: box.minY + b.minY * box.height, width: b.width * box.width, height: b.height * box.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, max(1, r.height * 0.8), nil)
            let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            let width = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.minY + r.height * 0.18)
            if width > 0 { ctx.scaleBy(x: r.width / width, y: 1) }
            ctx.textPosition = .zero
            CTLineDraw(ct, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}
