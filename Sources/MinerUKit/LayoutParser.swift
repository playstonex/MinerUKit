import Foundation

/// MinerU layout protocol parsing: `<|box_start|>x1 y1 x2 y2<|box_end|><|ref_start|>type<|ref_end|><|rotate_up|>`
///
/// Mirrors `MinerUClientHelper.parse_layout_output` of mineru-vl-utils 2.0.x:
/// unknown types are skipped, `unknown` becomes `image`, near-identical boxes
/// (IoU > 0.9, same type and angle) are collapsed, and `text` blocks that the
/// model flags as continuing the previous paragraph carry `mergePrev`.
public enum LayoutParser {

    public struct Box: Sendable, Equatable {
        public var x1: Double, y1: Double, x2: Double, y2: Double
        /// Taller title boxes map to higher heading levels.
        public var heightPercent: Double { (y2 - y1) * 100 }
        public var area: Double { max(0, x2 - x1) * max(0, y2 - y1) }
    }

    public struct Block: Sendable {
        public var type: String
        public var box: Box
        public var rotation: Rotation
        /// `text` block continuing the previous text block (`txt_contd_tgt`):
        /// a paragraph split across columns or pages.
        public var mergePrev: Bool = false
    }

    public enum Rotation: String, Sendable {
        case up, right, down, left
        /// Counter-clockwise degrees needed to make the crop upright. This is
        /// the upstream convention (PIL `Image.rotate`): right=90, down=180, left=270.
        public var angle: CGFloat {
            switch self {
            case .up: return 0
            case .right: return 90
            case .down: return 180
            case .left: return 270
            }
        }
    }

    /// MinerU boxes use a 0–1000 grid regardless of pixel size.
    public static let standardGrid = 1000.0

    /// Block types the model may emit (upstream `BLOCK_TYPES`).
    public static let knownTypes: Set<String> = [
        "text", "title", "doc_title", "paragraph_title", "table", "equation",
        "formula_number", "code", "algorithm", "aside_text", "ref_text", "index",
        "phonetic", "list_item", "caption", "table_caption", "image_caption",
        "code_caption", "footnote", "table_footnote", "image_footnote",
        "header", "footer", "page_number", "page_footnote",
        "image", "chart", "list", "image_block", "equation_block", "unknown",
    ]

    /// Block types that visually own their region.
    public static let containerTypes: Set<String> = ["table", "image", "chart", "image_block"]

    /// Upstream `INTERNAL_BLOCK_THRESHOLD`: a block counts as "inside" a
    /// container when at least this fraction of its area is covered.
    public static let internalThreshold = 0.9
    /// Upstream `LAYOUT_DEDUPLICATION_IOU_THRESHOLD`.
    public static let dedupIoU = 0.9

    static let regex = NSRegularExpression(
        #"<\|box_start\|>(\d+)\s+(\d+)\s+(\d+)\s+(\d+)<\|box_end\|><\|ref_start\|>(\w+?)<\|ref_end\|>(?:<\|rotate_(up|right|down|left)\|>)?(.*?)(?=<\|box_start\|>|$)"#,
        dotAll: true
    )

    /// Parses layout output. Order is preserved.
    /// - Parameter suppressOverlaps: drop blocks that sit inside a table / image
    ///   container (the container's own recognition already covers them).
    public static func parse(
        _ output: String,
        grid: Double = standardGrid,
        suppressOverlaps: Bool = true
    ) -> [Block] {
        let ns = output as NSString
        var blocks: [Block] = []
        for m in regex.matches(in: output, range: NSRange(location: 0, length: ns.length)) {
            guard let box = convert(
                m.group(1, in: ns), m.group(2, in: ns), m.group(3, in: ns), m.group(4, in: ns), grid: grid
            ) else { continue }
            var type = m.group(5, in: ns).lowercased()
            if type == "unknown" || type == "figure" { type = "image" }
            if type == "inline_formula" || !knownTypes.contains(type) { continue }
            let rotation = Rotation(rawValue: m.group(6, in: ns)) ?? .up
            let mergePrev = type == "text" && m.group(7, in: ns).contains("txt_contd_tgt")
            blocks.append(Block(type: type, box: box, rotation: rotation, mergePrev: mergePrev))
        }
        blocks = deduplicated(blocks)
        return suppressOverlaps ? suppressingOverlaps(in: blocks) : blocks
    }

    /// Upstream `_convert_bbox`: rejects coordinates outside the grid, swaps
    /// reversed corners, rejects zero-size boxes.
    static func convert(_ a: String, _ b: String, _ c: String, _ d: String, grid: Double) -> Box? {
        guard let x1 = Int(a), let y1 = Int(b), let x2 = Int(c), let y2 = Int(d) else { return nil }
        let values = [x1, y1, x2, y2].map(Double.init)
        guard values.allSatisfy({ $0 >= 0 && $0 <= grid }) else { return nil }
        let (lx, hx) = (min(values[0], values[2]), max(values[0], values[2]))
        let (ly, hy) = (min(values[1], values[3]), max(values[1], values[3]))
        guard lx != hx, ly != hy else { return nil }
        return Box(x1: lx / grid, y1: ly / grid, x2: hx / grid, y2: hy / grid)
    }

    // MARK: - Geometry

    static func intersectionArea(_ a: Box, _ b: Box) -> Double {
        let ix = min(a.x2, b.x2) - max(a.x1, b.x1)
        let iy = min(a.y2, b.y2) - max(a.y1, b.y1)
        return ix > 0 && iy > 0 ? ix * iy : 0
    }

    /// Fraction of `inner`'s area covered by `outer` (0…1).
    static func containment(_ inner: Box, in outer: Box) -> Double {
        let area = inner.area
        return area > 0 ? intersectionArea(inner, outer) / area : 0
    }

    // MARK: - Filtering

    /// IoU suppression among blocks of the same type and angle; the first
    /// occurrence wins.
    static func deduplicated(_ blocks: [Block]) -> [Block] {
        var kept: [Block] = []
        var groups: [String: [Block]] = [:]
        for block in blocks {
            let key = block.type + "|" + block.rotation.rawValue
            let isDuplicate = groups[key, default: []].contains { other in
                let inter = intersectionArea(block.box, other.box)
                let union = block.box.area + other.box.area - inter
                return union > 0 && inter / union > dedupIoU
            }
            if !isDuplicate {
                kept.append(block)
                groups[key, default: []].append(block)
            }
        }
        return kept
    }

    /// Removes blocks covered (≥ 90%) by a container:
    /// - text, equations and nested images inside a table (upstream drops
    ///   text/equations; images are our addition: the table crop already holds them);
    /// - captions, text and equations inside an image/chart/image_block
    ///   (upstream drops captions; we embed the whole picture, so labels
    ///   inside it would only add noise);
    /// - image/chart inside an image_block (not standalone).
    static func suppressingOverlaps(in blocks: [Block]) -> [Block] {
        var result = removeCovered(
            blocks,
            candidates: ["text", "equation", "equation_block", "image", "chart", "image_block"],
            containers: ["table"]
        )
        result = removeCovered(
            result,
            candidates: ["image_caption", "text", "equation", "equation_block"],
            containers: ["image", "chart", "image_block"]
        )
        return removeCovered(result, candidates: ["image", "chart"], containers: ["image_block"])
    }

    static func removeCovered(
        _ blocks: [Block], candidates: Set<String>, containers: Set<String>
    ) -> [Block] {
        let containerIndices = blocks.indices.filter { containers.contains(blocks[$0].type) }
        guard !containerIndices.isEmpty else { return blocks }
        return blocks.enumerated().compactMap { index, block in
            guard candidates.contains(block.type) else { return block }
            let covered = containerIndices.contains {
                $0 != index && containment(block.box, in: blocks[$0].box) >= internalThreshold
            }
            return covered ? nil : block
        }
    }

    /// True when other blocks sit inside `block`: for a `list` container they
    /// are recognized on their own, so the container itself must not be read.
    static func hasChildren(_ block: Block, in blocks: [Block]) -> Bool {
        blocks.contains { other in
            other.box != block.box && other.type != block.type
                && containment(other.box, in: block.box) >= internalThreshold
        }
    }
}
