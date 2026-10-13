import Testing
import Foundation
@testable import MinerUKit

@Suite("LayoutParser")
struct LayoutParserTests {

    @Test("parses boxes, types and rotation")
    func parseBasics() {
        let raw = """
        <|box_start|>312 058 713 073<|box_end|><|ref_start|>header<|ref_end|><|rotate_up|>
        <|box_start|>342 186 654 208<|box_end|><|ref_start|>title<|ref_end|><|rotate_up|>
        <|box_start|>023 268 061 701<|box_end|><|ref_start|>aside_text<|ref_end|><|rotate_left|>
        """
        let blocks = LayoutParser.parse(raw)
        #expect(blocks.count == 3)
        #expect(blocks[0].type == "header")
        #expect(blocks[0].box == LayoutParser.Box(x1: 0.312, y1: 0.058, x2: 0.713, y2: 0.073))
        #expect(blocks[1].type == "title")
        #expect(blocks[2].rotation == .left)
    }

    @Test("missing rotation defaults to up")
    func rotationDefault() {
        let raw = "<|box_start|>100 100 200 200<|box_end|><|ref_start|>text<|ref_end|>"
        #expect(LayoutParser.parse(raw).first?.rotation == .up)
    }

    @Test("drops degenerate and duplicate boxes")
    func dedupe() {
        let raw = """
        <|box_start|>100 100 200 200<|box_end|><|ref_start|>text<|ref_end|>
        <|box_start|>100 100 200 200<|box_end|><|ref_start|>text<|ref_end|>
        <|box_start|>101 100 200 200<|box_end|><|ref_start|>text<|ref_end|>
        <|box_start|>200 200 200 300<|box_end|><|ref_start|>text<|ref_end|>
        """
        #expect(LayoutParser.parse(raw).count == 1)
    }

    @Test("height percent drives heading levels")
    func heights() {
        let raw = "<|box_start|>100 100 500 400<|box_end|><|ref_start|>title<|ref_end|>"
        let h = LayoutParser.parse(raw).first?.box.heightPercent ?? 0
        #expect(abs(h - 30) < 1e-9)
    }

    @Test("blocks inside a table are suppressed as overlaps")
    func overlapSuppression() {
        let raw = """
        <|box_start|>100 100 600 500<|box_end|><|ref_start|>table<|ref_end|>
        <|box_start|>110 110 590 200<|box_end|><|ref_start|>text<|ref_end|>
        <|box_start|>110 210 590 490<|box_end|><|ref_start|>text<|ref_end|>
        <|box_start|>100 520 600 560<|box_end|><|ref_start|>text<|ref_end|>
        """
        let blocks = LayoutParser.parse(raw)
        #expect(blocks.count == 2)
        #expect(blocks.map(\.type) == ["table", "text"])
    }

    @Test("partially overlapping blocks are kept")
    func overlapTolerance() {
        let raw = """
        <|box_start|>100 100 600 500<|box_end|><|ref_start|>table<|ref_end|>
        <|box_start|>400 100 900 500<|box_end|><|ref_start|>text<|ref_end|>
        """
        #expect(LayoutParser.parse(raw).count == 2)
    }

    @Test("overlap suppression can be disabled")
    func overlapDisabled() {
        let raw = """
        <|box_start|>100 100 600 500<|box_end|><|ref_start|>table<|ref_end|>
        <|box_start|>110 110 590 200<|box_end|><|ref_start|>text<|ref_end|>
        """
        #expect(LayoutParser.parse(raw, suppressOverlaps: false).count == 2)
    }

    @Test("containment fraction")
    func containment() {
        let outer = LayoutParser.Box(x1: 0, y1: 0, x2: 1, y2: 1)
        let inner = LayoutParser.Box(x1: 0.1, y1: 0.1, x2: 0.9, y2: 0.9)
        let half = LayoutParser.Box(x1: 0.5, y1: 0, x2: 1.5, y2: 1)
        let disjoint = LayoutParser.Box(x1: 2, y1: 2, x2: 3, y2: 3)
        #expect(abs(LayoutParser.containment(inner, in: outer) - 1.0) < 1e-9)
        #expect(abs(LayoutParser.containment(half, in: outer) - 0.5) < 1e-9)
        #expect(LayoutParser.containment(disjoint, in: outer) == 0)
    }
}

@Suite("TableMarkdown")
struct TableMarkdownTests {

    @Test("simple rows become a markdown table")
    func simple() {
        let input = """
        intro
        <fcel>Layer<fcel>F1<nl>
        <fcel>A<fcel>88.3<nl>
        outro
        """
        let out = TableMarkdown.convert(input)
        #expect(out.contains("| Layer | F1 |"))
        #expect(out.contains("| --- | --- |"))
        #expect(out.contains("| A | 88.3 |"))
        #expect(out.contains("intro"))
        #expect(!out.contains("<fcel>"))
    }

    @Test("Table 3 pattern: merged header and empty cells")
    func mergedHeader() {
        let input = """
        <fcel>Model<fcel>BLEU<lcel> <fcel>Training Cost (FLOPs)<lcel> <fcel> <fcel>
        <fcel><ucel><fcel>EN-DE<fcel>EN-FR<fcel>EN-DE<fcel>EN-FR
        <fcel>ByteNet [18]<fcel>23.75<ecel><ecel><ecel>
        <fcel>GNMT + RL [38]<fcel>24.6<fcel>39.92<fcel>2.3·10^19<fcel>1.4·10^20
        """
        let out = TableMarkdown.convert(input)
        let lines = out.components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("| Model | BLEU |"))
        #expect(lines[1].contains("---"))
        #expect(lines[3].contains("| ByteNet [18] | 23.75 |"))
        #expect(lines[4].contains("2.3·10^19"))
        #expect(!out.contains("<lcel>"))
        #expect(!out.contains("<ucel>"))
        #expect(!out.contains("<ecel>"))
    }

    @Test("mixed text and table lines pass through")
    func passthrough() {
        let input = "plain line\n<fcel>a<nl>\nanother plain"
        let out = TableMarkdown.convert(input)
        #expect(out.contains("plain line"))
        #expect(out.contains("another plain"))
        #expect(out.contains("| a |"))
    }
}

@Suite("Assemble")
struct AssembleTests {

    func piece(_ kind: MinerUKit.Session.Piece.Kind, _ text: String) -> MinerUKit.Session.Piece {
        MinerUKit.Session.Piece(kind: kind, text: text)
    }

    @Test("distinct title heights map to heading levels 1…4")
    func headingLevels() {
        let long = String(repeating: "x", count: 80)
        let md = MinerUKit.Session.assemble([
            piece(.title(heightPercent: 40), "Big Title"),
            piece(.body, "para\n"),
            piece(.title(heightPercent: 20), "Section"),
            piece(.body, long + "\n"),
        ])
        let lines = md.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines[0] == "# Big Title")
        #expect(lines[2] == "## Section")
    }

    @Test("consecutive near-identical long bodies are collapsed")
    func adjacentDedup() {
        let body = String(repeating: "abc", count: 30)  // 90 chars
        let md = MinerUKit.Session.assemble([
            piece(.body, body + "\n"),
            piece(.body, body + "\n"),
            piece(.body, "different content entirely that is long enough " + String(repeating: "y", count: 40) + "\n"),
        ])
        #expect(md.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 2)
    }

    @Test("short repeated lines are not collapsed")
    func shortKept() {
        let md = MinerUKit.Session.assemble([
            piece(.body, "yes\n"),
            piece(.body, "yes\n"),
        ])
        #expect(md.components(separatedBy: "\n").filter { $0 == "yes" }.count == 2)
    }
}

@Suite("Display math")
struct MathTests {

    @Test("equation pipeline cleans spacing and wraps in $$")
    func wraps() {
        let blocks = [RecognizedBlock(
            type: "equation", box: .init(x1: 0, y1: 0, x2: 1, y2: 0.1), content: "E = mc^2"
        )]
        let out = PostProcess.pieces(from: blocks)
        #expect(out.first?.text == "$$\nE=mc^2\n$$\n")
    }

    @Test("delimiters already present are stripped and re-applied once")
    func passthrough() {
        for raw in ["$$E = mc^2$$", "\\[E = mc^2\\]"] {
            let blocks = [RecognizedBlock(
                type: "equation", box: .init(x1: 0, y1: 0, x2: 1, y2: 0.1), content: raw
            )]
            #expect(PostProcess.pieces(from: blocks).first?.text == "$$\nE=mc^2\n$$\n")
        }
    }

    @Test("bracket style matches the official pipeline")
    func brackets() {
        let blocks = [RecognizedBlock(
            type: "equation", box: .init(x1: 0, y1: 0, x2: 1, y2: 0.1), content: "x"
        )]
        #expect(PostProcess.pieces(from: blocks, style: .brackets).first?.text == "\\[\nx\n\\]\n")
    }
}

@Suite("NoRepeatNGramProcessor")
struct NoRepeatNGramTests {

    @Test("bans the token that would complete a repeated n-gram")
    func bansRepeat() {
        var p = NoRepeatNGramProcessor(ngramSize: 4)
        // sequence 1 2 3 4 1 2 3 …: after the 3-prefix "1 2 3" recurs,
        // token 4 is the completion of an already-seen n-gram.
        for t in [1, 2, 3, 4, 1, 2, 3] {
            p.register(t)
        }
        #expect(p.bannedTokens() == [4])
    }

    @Test("no ban before the first full n-gram")
    func needsHistory() {
        var p = NoRepeatNGramProcessor(ngramSize: 4)
        for t in [1, 2] {
            p.register(t)
        }
        #expect(p.bannedTokens() == nil)
    }

    @Test("unseen prefix has no bans")
    func unseenPrefix() {
        var p = NoRepeatNGramProcessor(ngramSize: 4)
        for t in [1, 2, 3, 4, 5, 6, 7] {
            p.register(t)
        }
        #expect(p.bannedTokens() == nil)
    }
}
