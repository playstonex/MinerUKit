import Foundation

/// Port of mineru-vl-utils `post_process/equation_*.py`: repairs the typical
/// LaTeX mistakes of the 1.2B recognizer so the result renders in KaTeX/MathJax.
///
/// Chain (same order as upstream): delimiters, `\left`/`\right` matching,
/// double subscripts, `\eqqcolon`/`\coloneqq`, `\big{)}` forms, `<` spacing,
/// unbalanced braces. Token spacing is removed first (``LatexCleaner``) so
/// that `\left (` and `\big {)}` already have their canonical shape.
enum EquationFixer {

    /// Full pipeline for one recognized equation (delimiters stripped, no `$$`).
    static func process(_ raw: String) -> String {
        var latex = stripDelimiters(raw)
        latex = LatexCleaner.clean(latex)
        latex = matchLeftRight(latex)
        latex = fixDoubleSubscript(latex)
        latex = fixColonEquals(latex)
        latex = fixBigDelimiters(latex)
        latex = latex.replacingOccurrences(of: "<", with: "< ")
        latex = removeUnbalancedBraces(latex)
        return latex
    }

    // MARK: - Delimiters

    /// Strips `\[ \]` (upstream) and `$$ $$` (what the model sometimes emits).
    static func stripDelimiters(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\\[", "\\]"), ("$$", "$$")] {
            if s.hasPrefix(open) { s = String(s.dropFirst(open.count)) }
            if s.hasSuffix(close) { s = String(s.dropLast(close.count)) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    // MARK: - Simple rewrites

    static let doubleSubscript = NSRegularExpression(
        #"_\s*\{(?:[^{}]|\{[^{}]*\})*\}\s*_\s*\{(?:[^{}]|\{[^{}]*\})*\}"#
    )

    /// `x_{a}_{b}` is invalid TeX; upstream deletes both subscripts.
    static func fixDoubleSubscript(_ latex: String) -> String {
        doubleSubscript.replacing(in: latex, with: "")
    }

    static func fixColonEquals(_ latex: String) -> String {
        latex.replacingOccurrences(of: "\\eqqcolon", with: "=:")
            .replacingOccurrences(of: "\\coloneqq", with: ":=")
    }

    // MARK: - \big{)} -> \big)

    /// Every `\big…`, `\Big…`, `\bigg…`, `\Bigg…` with optional l/r/m suffix.
    static let bigCommands: [String] = {
        var out: [String] = []
        for base in ["big", "Big", "bigg", "Bigg"] {
            for suffix in ["", "l", "r", "m"] { out.append("\\" + base + suffix) }
        }
        return out
    }()

    /// (wrapped form, bare form) pairs, e.g. `{)}` -> `)`. The trailing space
    /// after `\rangle`/`\langle` keeps the command from fusing with a letter.
    static let bigDelimiters: [(String, String)] = [
        ("{)}", ")"), ("{(}", "("),
        ("{\\}}", "\\}"), ("{\\{}", "\\{"),
        ("{|}", "|"), ("{\\|}", "\\|"),
        ("{]}", "]"), ("{[}", "["),
        ("{\\rangle}", "\\rangle "), ("{\\langle}", "\\langle "),
    ]

    static let bigRules: [(String, String)] = {
        var rules: [(String, String)] = []
        for command in bigCommands {
            for (wrapped, bare) in bigDelimiters {
                rules.append((command + wrapped, command + bare))
                rules.append((command + " " + wrapped, command + bare))
            }
        }
        return rules
    }()

    static func fixBigDelimiters(_ latex: String) -> String {
        guard latex.contains("\\big") || latex.contains("\\Big") else { return latex }
        var out = latex
        for (from, to) in bigRules where out.contains(from) {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out.replacingOccurrences(of: "\\bigtimes", with: "\\times")
    }

    // MARK: - Unbalanced braces

    /// Deletes `{`/`}` that cannot be paired; braces escaped by an odd number
    /// of backslashes are ignored.
    static func removeUnbalancedBraces(_ latex: String) -> String {
        let scalars = Array(latex.unicodeScalars)
        var stack: [Int] = []
        var unmatched = Set<Int>()
        for (i, scalar) in scalars.enumerated() where scalar == "{" || scalar == "}" {
            var backslashes = 0
            var j = i - 1
            while j >= 0, scalars[j] == "\\" { backslashes += 1; j -= 1 }
            if backslashes % 2 == 1 { continue }
            if scalar == "{" {
                stack.append(i)
            } else if stack.isEmpty {
                unmatched.insert(i)
            } else {
                stack.removeLast()
            }
        }
        unmatched.formUnion(stack)
        guard !unmatched.isEmpty else { return latex }
        var view = String.UnicodeScalarView()
        for (i, scalar) in scalars.enumerated() where !unmatched.contains(i) { view.append(scalar) }
        return String(view)
    }

    // MARK: - \left / \right

    static let leftTokens = [
        "\\left\\lbrace", "\\left\\lVert", "\\left\\lvert", "\\left\\rvert", "\\left\\rVert",
        "\\left\\vert", "\\left\\Vert", "\\left\\lfloor", "\\left\\lbrack", "\\left\\langle",
        "\\left|", "\\left\\|", "\\left[", "\\left]", "\\left(", "\\left)",
        "\\left\\{", "\\left\\}", "\\left.", "\\left/",
    ]
    static let rightTokens = [
        "\\right\\rbrace", "\\right\\lVert", "\\right\\lvert", "\\right\\rvert", "\\right\\rVert",
        "\\right\\vert", "\\right\\Vert", "\\right\\rfloor", "\\right\\rbrack", "\\right\\rangle",
        "\\right|", "\\right\\|", "\\right]", "\\right[", "\\right)", "\\right(",
        "\\right\\}", "\\right\\{", "\\right.", "\\right/",
    ]

    /// Counterpart of each left token (`\left.` / `\right.` pair with anything).
    static let closer: [String: String] = [
        "\\left\\lbrace": "\\right\\rbrace", "\\left\\lVert": "\\right\\lVert",
        "\\left\\lvert": "\\right\\lvert", "\\left\\rvert": "\\right\\rvert",
        "\\left\\rVert": "\\right\\rVert", "\\left\\vert": "\\right\\vert",
        "\\left\\Vert": "\\right\\Vert", "\\left\\lfloor": "\\right\\rfloor",
        "\\left\\lbrack": "\\right\\rbrack", "\\left\\langle": "\\right\\rangle",
        "\\left|": "\\right|", "\\left\\|": "\\right\\|",
        "\\left[": "\\right]", "\\left]": "\\right[",
        "\\left(": "\\right)", "\\left)": "\\right(",
        "\\left\\{": "\\right\\}", "\\left\\}": "\\right\\{",
        "\\left/": "\\right/",
    ]

    private static func alternation(_ tokens: [String]) -> String {
        tokens.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
    }

    static let leftRegex = NSRegularExpression(alternation(leftTokens))
    static let rightRegex = NSRegularExpression(alternation(rightTokens))
    static let anyTokenRegex = NSRegularExpression("(" + alternation(leftTokens + rightTokens) + ")")
    static let structureRegex = NSRegularExpression(
        #"(&|\\\\|\\begin\{array\}\s*\{[a-zA-Z\s]*\}|\\end\{array\})"#
    )

    static func isPair(_ left: String, _ right: String) -> Bool {
        guard left.hasPrefix("\\left"), right.hasPrefix("\\right") else { return false }
        return left == "\\left." || right == "\\right." || closer[left] == right
    }

    /// Adds `\right.` / `\left.` where a `\left` / `\right` has no partner.
    /// Skipped unless the counts differ and the `array` environments balance.
    static func matchLeftRight(_ latex: String) -> String {
        guard leftRegex.count(in: latex) != rightRegex.count(in: latex) else { return latex }
        guard latex.components(separatedBy: "\\begin{array}").count
                == latex.components(separatedBy: "\\end{array}").count else { return latex }
        return fixMismatch(latex)
    }

    private struct CellTag: Hashable {
        var array: Int
        var cell: Int
    }

    private static func isStructural(_ node: String) -> Bool {
        node == "&" || node == "\\\\" || node.contains("\\begin{array}") || node.contains("\\end{array}")
    }

    /// Cell tag `(array, cell index)` of every node, so a `\left` in one
    /// `array` cell is only matched with a `\right` of the same cell. Without
    /// any `array` the whole formula is a single cell (aligned/cases may
    /// legitimately open a delimiter in one row and close it in another).
    /// Returns nil for malformed nesting.
    private static func tagNodes(_ nodes: [String]) -> [CellTag?]? {
        struct Span { var tag: Int; var start: Int; var end: Int }
        var spans: [Span] = []
        var open: [(tag: Int, start: Int)] = []
        var counter = 0
        for (i, node) in nodes.enumerated() {
            if node.contains("\\begin{array}") {
                counter += 1
                open.append((counter, i))
            } else if node == "\\end{array}" {
                guard let top = open.popLast() else { return nil }
                spans.append(Span(tag: top.tag, start: top.start, end: i))
            }
        }
        guard open.isEmpty else { return nil }
        if spans.isEmpty { return nodes.map { _ in CellTag(array: 0, cell: 0) } }

        // Outermost arrays first; nodes of nested arrays belong to the inner one.
        let nested = spans.map { outer in
            spans.filter { outer.start < $0.start && outer.end > $0.end }
        }
        let order = spans.indices.sorted { nested[$0].count > nested[$1].count }
        var result = [CellTag?](repeating: nil, count: nodes.count)
        for index in order {
            let span = spans[index]
            var masked = Set<Int>()
            for inner in nested[index] { masked.formUnion(inner.start...inner.end) }
            var cell = 0
            for i in span.start...span.end where !masked.contains(i) {
                if nodes[i] == "&" || nodes[i] == "\\\\" { cell += 1; continue }
                if result[i] == nil { result[i] = CellTag(array: span.tag, cell: cell) }
            }
        }
        return result
    }

    private static func fixMismatch(_ latex: String) -> String {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let nodes = structureRegex.splitKeepingGroups(trimmed)
            .filter { !$0.isEmpty }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let tags = tagNodes(nodes) else { return latex }

        var groups: [CellTag?: [Int]] = [:]
        var groupOrder: [CellTag?] = []
        for (i, node) in nodes.enumerated() where !isStructural(node) {
            if groups[tags[i]] == nil { groupOrder.append(tags[i]) }
            groups[tags[i], default: []].append(i)
        }

        var fixedNodes = nodes
        for tag in groupOrder {
            let indices = groups[tag]!
            let texts = indices.map { nodes[$0] }
            let lefts = texts.reduce(0) { $0 + leftRegex.count(in: $1) }
            let rights = texts.reduce(0) { $0 + rightRegex.count(in: $1) }
            guard lefts != rights else { continue }

            var pieces = texts.map { text in
                anyTokenRegex.splitKeepingGroups(text)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
            var stack: [(token: String, si: Int, ti: Int)] = []
            for (si, list) in pieces.enumerated() {
                for (ti, token) in list.enumerated()
                where leftTokens.contains(token) || rightTokens.contains(token) {
                    if let top = stack.last, isPair(top.token, token) {
                        stack.removeLast()
                    } else {
                        stack.append((token, si, ti))
                    }
                }
            }
            for entry in stack {
                if entry.token.contains("\\left") {
                    pieces[entry.si][entry.ti] += " \\right."
                } else {
                    pieces[entry.si][entry.ti] = "\\left. " + pieces[entry.si][entry.ti]
                }
            }
            for (k, index) in indices.enumerated() { fixedNodes[index] = pieces[k].joined() }
        }
        return fixedNodes.joined()
    }

    // MARK: - equation_block

    static let tagRegex = NSRegularExpression(#"\\tag\s*\{([^}]*)\}"#)

    /// Several equations stacked inside one `equation_block` become a single
    /// left-aligned `array`. LaTeX allows one `\tag` per display, so multiple
    /// tags turn into plain `(n)` labels.
    static func combine(_ equations: [String]) -> String {
        let tagTotal = equations.reduce(0) { $0 + tagRegex.count(in: $1) }
        let parts = tagTotal > 1
            ? equations.map { eq in tagRegex.replacing(in: eq) { m, ns in "(" + m.group(1, in: ns) + ")" } }
            : equations
        return "\\begin{array}{l} " + parts.map { $0 + " \\\\ " }.joined() + "\\end{array}"
    }
}
