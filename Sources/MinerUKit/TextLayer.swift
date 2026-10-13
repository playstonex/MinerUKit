import Foundation
import PDFKit

/// Native PDF text-layer extraction for the fast tiers (flash / basic).
///
/// PDF text layers are line-oriented and lose paragraph structure; this
/// reassembles flowing paragraphs, keeps list items as separate blocks, and
/// de-hyphenates line-broken words. Latin lines join with a space, CJK lines
/// join directly (no space), matching typographic convention.
enum TextLayer {

    /// Raw text-layer string of each page ("" when the page has none).
    static func pageTexts(of url: URL) -> [String] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<document.pageCount).map { index in
            document.page(at: index)?.string ?? ""
        }
    }

    /// A page is worth the fast path when its text layer carries real content
    /// (≥32 non-whitespace characters) — page numbers and stray labels don't count.
    static func isTextDense(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 32
    }

    /// Reassembles line-broken page text into markdown blocks (paragraphs and
    /// list items), joined by blank lines.
    static func markdownBlocks(_ raw: String) -> String {
        let paragraphs = reassemble(raw.components(separatedBy: .newlines).map(removeGeneratedCJKSpaces))
        return paragraphs.joined(separator: "\n\n")
    }

    /// Drops the spaces PDF producers synthesize between adjacent Chinese
    /// characters (`卫 星 技 术` -> `卫星技术`). Upstream decides this from glyph
    /// geometry; the plain string has no geometry, so the rule is: whitespace
    /// with a CJK character on both sides goes, whitespace next to Latin text
    /// or digits stays (`中 文 InSAR 技术` -> `中文 InSAR 技术`).
    static func removeGeneratedCJKSpaces(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count > 2 else { return line }
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == " " || scalar == "\u{00A0}" || scalar == "\u{3000}" {
                var j = i
                while j < scalars.count, scalars[j] == " " || scalars[j] == "\u{00A0}" || scalars[j] == "\u{3000}" {
                    j += 1
                }
                if let before = out.last, j < scalars.count, isCJK(before), isCJK(scalars[j]) {
                    i = j
                    continue
                }
            }
            out.append(scalar)
            i += 1
        }
        return String(out)
    }

    // MARK: - Paragraph reassembly

    static let listPrefix = try! NSRegularExpression(
        pattern: #"^(?:[-*+•]\s+|\d{1,3}[.)]\s+|[a-zA-Z][.)]\s+)"#
    )

    static func isListStart(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return listPrefix.firstMatch(in: line, range: range) != nil
    }

    static func reassemble(_ lines: [String]) -> [String] {
        var blocks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { blocks.append(trimmed) }
            current = ""
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if current.isEmpty || isListStart(line) {
                if !current.isEmpty { flush() }
                current = line
            } else {
                current = join(current, line)
            }
        }
        flush()
        return blocks
    }

    /// Joins a wrapped line onto the accumulating paragraph.
    static func join(_ previous: String, _ next: String) -> String {
        // de-hyphenate: "signifi-" + "cantly" -> "significantly"
        if previous.hasSuffix("-"), let first = next.first, first.isASCII, first.isLetter {
            return String(previous.dropLast()) + next
        }
        if endsCJK(previous) || startsCJK(next) {
            return previous + next
        }
        return previous + " " + next
    }

    static func startsCJK(_ s: String) -> Bool {
        guard let scalar = s.unicodeScalars.first else { return false }
        return isCJK(scalar)
    }

    static func endsCJK(_ s: String) -> Bool {
        guard let scalar = s.unicodeScalars.last else { return false }
        return isCJK(scalar)
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,   // CJK Unified Ideographs
             0x3400...0x4DBF,   // Extension A
             0x3040...0x30FF,   // Hiragana / Katakana
             0xAC00...0xD7AF,   // Hangul syllables
             0x3001...0x303F,   // CJK punctuation (excluding the ideographic space)
             0xFF00...0xFFEF:   // fullwidth forms
            return true
        default:
            return false
        }
    }
}
