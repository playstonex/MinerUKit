import Foundation

/// MinerU layout protocol parsing: `<|box_start|>x1 y1 x2 y2<|box_end|><|ref_start|>type<|ref_end|><|rotate_up|>`
public enum LayoutParser {

    public struct Box: Sendable, Equatable {
        public var x1: Double, y1: Double, x2: Double, y2: Double
        /// Taller title boxes map to higher heading levels.
        public var heightPercent: Double { (y2 - y1) * 100 }
    }

    public struct Block: Sendable {
        public var type: String
        public var box: Box
        public var rotation: Rotation
    }

    public enum Rotation: String, Sendable {
        case up, right, down, left
        public var angle: CGFloat {
            switch self {
            case .right: return -90
            case .down: return 180
            case .left: return 90
            case .up: return 0
            }
        }
    }

    /// MinerU boxes use a 0–1000 grid regardless of pixel size.
    public static let standardGrid = 1000.0

    /// Block types that visually own their region: anything detected inside
    /// them is re-emitted separately by the model and would be double-rendered.
    public static let containerTypes: Set<String> = [
        "table", "figure", "image", "chart", "image_block",
    ]

    static let regex = try! NSRegularExpression(
        pattern: #"\<\|box_start\|>(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\<\|box_end\|>\<\|ref_start\|>(\w+?)\<\|ref_end\|>(?:\<\|rotate_(\w+)\|>)?"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Parses layout output. The 1.2B model can loop near-identical boxes;
    /// exact duplicates (same type + box) are dropped. Blocks ≥85% contained
    /// inside a container-type block (table/figure/…) are dropped as overlaps.
    /// Order is preserved.
    public static func parse(
        _ output: String,
        grid: Double = standardGrid,
        suppressOverlaps: Bool = true
    ) -> [Block] {
        let range = NSRange(output.startIndex..., in: output)
        var blocks: [Block] = []
        var seen = Set<String>()
        for match in regex.matches(in: output, range: range) {
            func g(_ i: Int) -> String {
                guard let r = Range(match.range(at: i), in: output) else { return "" }
                return String(output[r])
            }
            let box = Box(
                x1: (Double(g(1)) ?? 0) / grid,
                y1: (Double(g(2)) ?? 0) / grid,
                x2: (Double(g(3)) ?? 0) / grid,
                y2: (Double(g(4)) ?? 0) / grid
            )
            let type = g(5)
            let rotation = Rotation(rawValue: g(6)) ?? .up
            guard box.x2 > box.x1, box.y2 > box.y1 else { continue }
            let key = "\(type)|\(box.x1),\(box.y1),\(box.x2),\(box.y2)"
            guard seen.insert(key).inserted else { continue }
            blocks.append(Block(type: type, box: box, rotation: rotation))
        }
        return suppressOverlaps ? suppressingOverlaps(in: blocks) : blocks
    }

    /// Fraction of `inner`'s area covered by `outer` (0…1).
    static func containment(_ inner: Box, in outer: Box) -> Double {
        let ix = min(inner.x2, outer.x2) - max(inner.x1, outer.x1)
        let iy = min(inner.y2, outer.y2) - max(inner.y1, outer.y1)
        guard ix > 0, iy > 0 else { return 0 }
        let innerArea = (inner.x2 - inner.x1) * (inner.y2 - inner.y1)
        return ix * iy / innerArea
    }

    static func suppressingOverlaps(in blocks: [Block]) -> [Block] {
        let containers = blocks.filter { containerTypes.contains($0.type) }
        guard !containers.isEmpty else { return blocks }
        return blocks.filter { block in
            if containerTypes.contains(block.type) { return true }
            return !containers.contains { containment(block.box, in: $0.box) >= 0.85 }
        }
    }
}
