import Foundation

// Small helpers that give NSRegularExpression the Python `re` behaviours the
// upstream post-processing relies on (`re.sub` with a callback, `re.split`
// with a capture group).

extension NSRegularExpression {

    /// Compiles a pattern known to be valid at build time.
    convenience init(_ pattern: String, dotAll: Bool = false) {
        // swiftlint:disable:next force_try
        try! self.init(pattern: pattern, options: dotAll ? [.dotMatchesLineSeparators] : [])
    }

    /// `re.sub(pattern, callback, s)`.
    func replacing(
        in s: String,
        _ transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += transform(m, ns)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// `re.sub(pattern, literal, s)` (the replacement is NOT a template).
    func replacing(in s: String, with literal: String) -> String {
        replacing(in: s) { _, _ in literal }
    }

    /// `re.split(pattern, s)`: captured groups are kept in the result,
    /// empty pieces included, exactly like Python.
    func splitKeepingGroups(_ s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        var last = 0
        for m in matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            for g in 1..<max(m.numberOfRanges, 1) where m.range(at: g).location != NSNotFound {
                out.append(ns.substring(with: m.range(at: g)))
            }
            last = m.range.location + m.range.length
        }
        out.append(ns.substring(from: last))
        return out
    }

    /// `len(re.findall(pattern, s))`.
    func count(in s: String) -> Int {
        numberOfMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    func isMatch(_ s: String) -> Bool { count(in: s) > 0 }
}

extension NSTextCheckingResult {
    func group(_ i: Int, in ns: NSString) -> String {
        let r = range(at: i)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
    }
}
