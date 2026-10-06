import Foundation

/// Converts MinerU's native table markup into GitHub-flavored Markdown tables.
///
/// MinerU emits rows as `<fcel>cell<fcel>cell<nl>`; `<lcel>`/`<ucel>` mark
/// left/up merged continuation cells and `<ecel>` empty cells (col/rowspan).
/// Markdown has no span support, so merged continuations become empty columns.
public enum TableMarkdown {

    static let cellMark = try! NSRegularExpression(pattern: #"<lcel>|<ucel>|<ecel>"#)

    /// Converts every table chunk in `text`; non-table lines pass through unchanged.
    public static func convert(_ text: String) -> String {
        var lines: [String] = []
        var buffer: [String] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            lines.append(contentsOf: markdownRows(buffer))
            buffer.removeAll()
        }
        for line in text.components(separatedBy: "\n") {
            if line.contains("<fcel>") || line.contains("<nl>") {
                buffer.append(line)
            } else {
                flush()
                lines.append(line)
            }
        }
        flush()
        return lines.joined(separator: "\n") + "\n"
    }

    struct Row {
        var cells: [String]
    }

    /// One `<fcel>`-delimited cell -> flat columns. Trailing `<lcel>/<ucel>/<ecel>`
    /// markers add merged/empty columns; a marker-only cell is a single empty column.
    static func expandCell(_ cell: String) -> [String] {
        let full = NSRange(cell.startIndex..., in: cell)
        let marks = cellMark.matches(in: cell, range: full)
        var pieces: [String] = []
        var cursor = cell.startIndex
        for m in marks {
            guard let r = Range(m.range, in: cell) else { continue }
            pieces.append(String(cell[cursor..<r.lowerBound]))
            cursor = r.upperBound
        }
        pieces.append(String(cell[cursor...]))
        let content = pieces[0].trimmingCharacters(in: .whitespaces)
        let markCount = pieces.count - 1
        if !content.isEmpty {
            return [content] + [String](repeating: "", count: markCount)
        }
        return [String](repeating: "", count: max(1, markCount))
    }

    static func markdownRows(_ chunk: [String]) -> [String] {
        var rows: [[String]] = []
        for line in chunk {
            for raw in line.replacingOccurrences(of: "<nl>", with: "\n").components(separatedBy: "\n") {
                guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                var cells: [String] = []
                var pieces = raw.components(separatedBy: "<fcel>")
                if raw.hasPrefix("<fcel>") { pieces.removeFirst() }  // leading <fcel> opens the first cell
                for piece in pieces {
                    cells.append(contentsOf: expandCell(piece))
                }
                if cells.contains(where: { !$0.isEmpty }) {
                    rows.append(cells)
                }
            }
        }
        guard let width = rows.map(\.count).max(), !rows.isEmpty else { return [] }
        let padded = rows.map { $0 + [String](repeating: "", count: width - $0.count) }
        var out = ["| " + padded[0].joined(separator: " | ") + " |"]
        out.append("|" + [String](repeating: " --- ", count: width).joined(separator: "|") + "|")
        for r in padded.dropFirst() {
            out.append("| " + r.joined(separator: " | ") + " |")
        }
        return out
    }
}
