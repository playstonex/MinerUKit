import Foundation

/// How display equations are delimited in the Markdown output.
public enum DisplayMathStyle: Sendable {
    /// `$$ … $$`: understood by GitHub, Typora, Obsidian and most renderers.
    case dollars
    /// `\[ … \]`: what the official MinerU pipeline emits. Many CommonMark
    /// renderers treat `\[` as an escaped bracket and show a literal `[`.
    case brackets
}

/// One recognized layout block, before it becomes Markdown. Everything the
/// upstream `post_process` needs (type, box, text) without any model state, so
/// the whole chain is unit-testable.
struct RecognizedBlock {
    var type: String
    var box: LayoutParser.Box
    var content: String
    var mergePrev = false
    /// File name of the saved crop for image-like blocks.
    var imageName: String?
}

/// Port of mineru-vl-utils `post_process/__init__.py` plus the text helpers
/// (`text_display2inline`, `text_inline_spacing`, `text_move_underscores_outside`).
enum PostProcess {

    static let nonTextPlaceholder = "[Non-Text]"

    /// Types whose recognized text is a heading.
    static let titleTypes: Set<String> = ["title", "doc_title", "paragraph_title"]

    // MARK: - Blocks -> pieces

    /// Turns page blocks into Markdown pieces: drops `[Non-Text]` placeholders,
    /// repairs equations, merges `equation_block` groups and cleans prose.
    static func pieces(
        from blocks: [RecognizedBlock],
        style: DisplayMathStyle = .dollars,
        skipTypes: Set<String> = []
    ) -> [MinerUKit.Session.Piece] {
        typealias Piece = MinerUKit.Session.Piece

        // 1. Placeholder blocks are model noise ("nothing to read here").
        var items = blocks.filter { block in
            block.imageName != nil
                || block.content.trimmingCharacters(in: .whitespacesAndNewlines) != nonTextPlaceholder
        }

        // 2. Equation repair, then `equation_block` merging.
        for i in items.indices where items[i].type == "equation" && items[i].imageName == nil {
            items[i].content = EquationFixer.process(items[i].content)
        }
        items = mergeEquationBlocks(items)

        // 3. Markdown.
        var pieces: [Piece] = []
        for block in items {
            if let name = block.imageName {
                pieces.append(Piece(kind: .body, text: "![](\(name))\n"))
                continue
            }
            if skipTypes.contains(block.type) || block.type == "equation_block" { continue }
            let trimmed = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            switch block.type {
            case "equation":
                pieces.append(Piece(kind: .equation, text: displayMath(trimmed, style: style) + "\n"))
            case "table":
                pieces.append(Piece(
                    kind: .table,
                    text: LatexCleaner.cleanDelimitedMath(in: TableMarkdown.convert(trimmed))
                ))
            case let type where titleTypes.contains(type):
                pieces.append(Piece(
                    kind: .title(heightPercent: block.box.heightPercent),
                    text: prose(trimmed)
                ))
            default:
                // `list_item` is plain text upstream; only `text` can continue
                // the previous paragraph.
                let isText = block.type == "text" || block.type == "list_item"
                pieces.append(Piece(
                    kind: .body, text: prose(trimmed) + "\n",
                    isText: isText, mergePrev: block.type == "text" && block.mergePrev
                ))
            }
        }
        return pieces
    }

    /// Replaces the `equation`s covered by an `equation_block` with one
    /// combined equation (only when it covers more than one); other
    /// `equation_block`s are dropped, like upstream.
    static func mergeEquationBlocks(_ blocks: [RecognizedBlock]) -> [RecognizedBlock] {
        var covered: [Int: [Int]] = [:]
        for (i, block) in blocks.enumerated() where block.type == "equation_block" {
            let spans = blocks.indices.filter { j in
                blocks[j].type == "equation"
                    && LayoutParser.containment(blocks[j].box, in: block.box) > LayoutParser.internalThreshold
            }
            if spans.count > 1 { covered[i] = spans }
        }
        let swallowed = Set(covered.values.flatMap { $0 })
        var out: [RecognizedBlock] = []
        for (i, block) in blocks.enumerated() {
            if swallowed.contains(i) { continue }
            if let spans = covered[i] {
                var merged = block
                merged.type = "equation"
                merged.content = EquationFixer.combine(spans.map { blocks[$0].content })
                out.append(merged)
            } else if block.type != "equation_block" {
                out.append(block)
            }
        }
        return out
    }

    // MARK: - Equations

    /// Wraps already repaired LaTeX as a display equation.
    static func displayMath(_ latex: String, style: DisplayMathStyle) -> String {
        let body = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        switch style {
        case .dollars: return "$$\n\(body)\n$$"
        case .brackets: return "\\[\n\(body)\n\\]"
        }
    }

    // MARK: - Prose

    /// Inline-math repairs for paragraph/heading/caption text.
    static func prose(_ text: String) -> String {
        var s = displayToInline(text)
        s = fixMacroSpacing(s)
        s = moveUnderscoresOutside(s)
        return LatexCleaner.cleanDelimitedMath(in: s)
    }

    private static let displayRegex = NSRegularExpression(#"\\\[(.*?)\\\]"#, dotAll: true)
    private static let citationLike = NSRegularExpression(#"[–\d\-,\s]+"#)

    /// `\[x\]` inside running text is an inline formula, except citation-like
    /// content (`\[1, 2\]`, `\[3-5\]`) which stays as it is.
    static func displayToInline(_ text: String) -> String {
        displayRegex.replacing(in: text) { m, ns in
            let inner = m.group(1, in: ns)
            return citationLike.fullMatches(inner) ? "\\[" + inner + "\\]" : "\\(" + inner + "\\)"
        }
    }

    private static let inlineSplit = NSRegularExpression(#"(\\\(.*?\\\))"#, dotAll: true)
    static let targetMacros = ["\\cong", "\\to", "\\times", "\\subset", "\\in"]
    static let knownMacros: Set<String> = ["\\top", "\\int", "\\inf"]

    /// `\timesX` -> `\times X` inside `\( … \)`: the model sometimes drops the
    /// space after these macros, which would fuse them with the next letter.
    static func fixMacroSpacing(_ text: String) -> String {
        inlineSplit.splitKeepingGroups(text).map { part in
            guard part.hasPrefix("\\("), part.hasSuffix("\\)"), part.count >= 4 else { return part }
            let inner = String(part.dropFirst(2).dropLast(2))
            return "\\(" + fixMacros(in: inner) + "\\)"
        }.joined()
    }

    private static func fixMacros(in inner: String) -> String {
        var text = inner
        for macro in targetMacros {
            let regex = NSRegularExpression(NSRegularExpression.escapedPattern(for: macro) + "([a-zA-Z])(?![a-zA-Z])")
            text = regex.replacing(in: text) { m, ns in
                let letter = m.group(1, in: ns)
                return knownMacros.contains(macro + letter) ? m.group(0, in: ns) : macro + " " + letter
            }
        }
        return text
    }

    private static let inlineRegex = NSRegularExpression(#"\\\((.+?)\\\)"#, dotAll: true)
    private static let underscoreSplit = NSRegularExpression("(_{3,})")
    private static let underscoreRun = NSRegularExpression("_{3,}")

    /// Fill-in blanks (`____`) belong to the text, not to the formula:
    /// `\( a ___ b \)` -> `\( a \) ___ \( b \)`.
    static func moveUnderscoresOutside(_ text: String) -> String {
        inlineRegex.replacing(in: text) { m, ns in
            let inner = m.group(1, in: ns)
            let parts = underscoreSplit.splitKeepingGroups(inner)
            guard parts.count > 1 else { return m.group(0, in: ns) }
            var out: [String] = []
            for part in parts {
                if underscoreRun.fullMatches(part) {
                    out.append(part)
                } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append("\\(" + part + "\\)")
                }
            }
            return out.joined(separator: " ")
        }
    }

    // MARK: - Paragraph merging (json2md)

    private static let han = NSRegularExpression(#"[\u4e00-\u9fff\u3400-\u4dbf]"#)

    /// Appends a continuation to its predecessor: no space when the added
    /// text contains Chinese, one space otherwise (upstream `json2md`).
    static func joinContinuation(_ previous: String, _ next: String) -> String {
        let head = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        return head + (han.isMatch(next) ? "" : " ") + next
    }
}

extension NSRegularExpression {
    /// True when the whole string matches (Python `re.fullmatch`).
    func fullMatches(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: (s as NSString).length)
        guard let m = firstMatch(in: s, options: [.anchored], range: range) else { return false }
        return m.range == range
    }
}
