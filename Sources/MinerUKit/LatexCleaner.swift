import Foundation

/// Removes the token-by-token spacing the recognizer emits in LaTeX
/// (`\frac {Q K ^ {T}}` -> `\frac{QK^{T}}`) without changing how it renders.
///
/// Whitespace is dropped everywhere in math mode, except:
/// - after a control word when the next character is a letter (`\alpha x`),
///   otherwise the two would fuse into a different command;
/// - inside the argument of text-mode commands (`\text{ if }`), where spaces
///   are significant (runs are collapsed to one space);
/// - control spaces (`\ `), which are a command, not whitespace.
enum LatexCleaner {

    /// Commands whose braced argument is typeset in text mode.
    static let textCommands: Set<String> = [
        "text", "textbf", "textit", "textrm", "textsf", "texttt", "textnormal",
        "mbox", "hbox",
    ]

    /// Cleans one math expression (no surrounding delimiters).
    static func clean(_ input: String) -> String {
        let chars = Array(input.trimmingCharacters(in: .whitespacesAndNewlines))
        // `%` starts a comment that runs to end of line; joining lines would
        // swallow the rest of the formula, so leave such input alone.
        if hasUnescapedPercent(chars) { return String(chars) }

        var out = ""
        var i = 0
        let n = chars.count
        while i < n {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            guard c == "\\" else { out.append(c); i += 1; continue }

            // Control symbol (`\\`, `\,`, `\{`, `\ `, ...): copy both characters.
            guard i + 1 < n, isASCIILetter(chars[i + 1]) else {
                out.append(c)
                if i + 1 < n { out.append(chars[i + 1]) }
                i += 2
                continue
            }

            // Control word.
            var j = i + 1
            while j < n, isASCIILetter(chars[j]) { j += 1 }
            let name = String(chars[(i + 1)..<j])
            out.append(contentsOf: chars[i..<j])

            var k = j
            while k < n, chars[k].isWhitespace { k += 1 }

            if textCommands.contains(name), k < n, chars[k] == "{",
               let end = matchingBrace(chars, from: k) {
                out.append("{")
                out.append(collapseWhitespace(chars[(k + 1)..<end]))
                out.append("}")
                i = end + 1
                continue
            }
            if k > j, k < n, isASCIILetter(chars[k]) { out.append(" ") }
            i = k
        }
        return out
    }

    /// Cleans every `\( ... \)` and `\[ ... \]` span found in running text
    /// (inline formulas inside paragraphs, titles, and table cells).
    static func cleanDelimitedMath(in text: String) -> String {
        let pairs = [("\\(", "\\)"), ("\\[", "\\]")]
        var result = ""
        var rest = Substring(text)
        while true {
            // Earliest opener of either kind.
            var best: (range: Range<Substring.Index>, close: String)?
            for (open, close) in pairs {
                if let r = rest.range(of: open),
                   best == nil || r.lowerBound < best!.range.lowerBound {
                    best = (r, close)
                }
            }
            guard let (openRange, close) = best,
                  let closeRange = rest.range(of: close, range: openRange.upperBound..<rest.endIndex)
            else { break }
            result += rest[..<openRange.lowerBound]
            result += rest[openRange]
            result += clean(String(rest[openRange.upperBound..<closeRange.lowerBound]))
            result += rest[closeRange]
            rest = rest[closeRange.upperBound...]
        }
        result += rest
        return result
    }

    // MARK: - Helpers

    private static func isASCIILetter(_ c: Character) -> Bool {
        c.isASCII && c.isLetter
    }

    private static func hasUnescapedPercent(_ chars: [Character]) -> Bool {
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "%" { return true }
            i += 1
        }
        return false
    }

    /// Index of the `}` matching the `{` at `open`, honoring `\{` / `\}`.
    private static func matchingBrace(_ chars: [Character], from open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < chars.count {
            switch chars[i] {
            case "\\": i += 1
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        return nil
    }

    /// Replaces each whitespace run with a single space (edges included).
    private static func collapseWhitespace(_ chars: ArraySlice<Character>) -> String {
        var out = ""
        var inSpace = false
        for c in chars {
            if c.isWhitespace {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(c)
                inSpace = false
            }
        }
        return out
    }
}
