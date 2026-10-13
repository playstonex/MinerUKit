import Testing
import Foundation
import CoreGraphics
@testable import MinerUKit

@Suite("EquationFixer")
struct EquationFixerTests {

    @Test("strips display delimiters")
    func delimiters() {
        #expect(EquationFixer.stripDelimiters("\\[a \\coloneqq b\\]") == "a \\coloneqq b")
        #expect(EquationFixer.stripDelimiters("$$ x $$") == "x")
    }

    @Test("eqqcolon / coloneqq")
    func colon() {
        #expect(EquationFixer.fixColonEquals("a \\coloneqq b \\eqqcolon c") == "a := b =: c")
    }

    @Test("double subscripts are removed")
    func doubleSubscript() {
        #expect(EquationFixer.fixDoubleSubscript("x_{a}_{b}+y_{c}") == "x+y_{c}")
        #expect(EquationFixer.fixDoubleSubscript("x_{a_1}_{b}") == "x")
    }

    @Test("big delimiters lose their braces")
    func big() {
        #expect(EquationFixer.fixBigDelimiters("\\big{)} \\Bigl{(} \\bigg {]}") == "\\big) \\Bigl( \\bigg]")
        #expect(EquationFixer.fixBigDelimiters("\\big{\\}}") == "\\big\\}")
        #expect(EquationFixer.fixBigDelimiters("\\Big{|}") == "\\Big|")
        #expect(EquationFixer.fixBigDelimiters("\\biggl{\\|}") == "\\biggl\\|")
        #expect(EquationFixer.fixBigDelimiters("\\bigr{\\rangle}x") == "\\bigr\\rangle x")
        #expect(EquationFixer.fixBigDelimiters("a\\bigtimes b") == "a\\times b")
    }

    @Test("unbalanced braces are deleted, escaped ones kept")
    func braces() {
        #expect(EquationFixer.removeUnbalancedBraces("\\frac{a}{b}}") == "\\frac{a}{b}")
        #expect(EquationFixer.removeUnbalancedBraces("{{a}") == "{a}")
        #expect(EquationFixer.removeUnbalancedBraces("\\{a\\}") == "\\{a\\}")
        #expect(EquationFixer.removeUnbalancedBraces("\\\\{a}") == "\\\\{a}")
    }

    @Test("missing \\right is supplied")
    func leftWithoutRight() {
        let fixed = EquationFixer.matchLeftRight("\\left( a + b")
        // Upstream places the filler right behind the orphan token.
        #expect(fixed.hasPrefix("\\left( \\right."))
        #expect(EquationFixer.leftRegex.count(in: fixed) == EquationFixer.rightRegex.count(in: fixed))
    }

    @Test("missing \\left is supplied")
    func rightWithoutLeft() {
        let fixed = EquationFixer.matchLeftRight("a + b \\right)")
        #expect(fixed.contains("\\left."))
        #expect(EquationFixer.leftRegex.count(in: fixed) == EquationFixer.rightRegex.count(in: fixed))
    }

    @Test("balanced formulas are untouched")
    func balanced() {
        let s = "\\left( a \\right) + \\left[ b \\right]"
        #expect(EquationFixer.matchLeftRight(s) == s)
    }

    @Test("array cells are repaired independently")
    func arrayCells() {
        // Global counts differ (2 vs 1), so every cell is checked on its own.
        let s = "\\begin{array}{ll} \\left( a & b \\right) \\\\ \\left[ c & d \\end{array}"
        let fixed = EquationFixer.matchLeftRight(s)
        #expect(fixed.contains("\\left( \\right. a"))
        #expect(fixed.contains("b \\left. \\right)"))
        #expect(fixed.contains("\\left[ \\right. c"))
    }

    @Test("counts are compared over the whole formula, like upstream")
    func globalCounts() {
        let s = "\\begin{array}{ll} \\left( a & b \\right) \\\\ \\end{array}"
        #expect(EquationFixer.matchLeftRight(s) == s)
    }

    @Test("full chain on a messy recognizer output")
    func chain() {
        let raw = "\\[ \\mathcal {L} = \\sum _ {i} x _ {i} _ {j} + \\left( y \\]"
        let out = EquationFixer.process(raw)
        #expect(!out.contains("_{j}"))
        #expect(!out.hasPrefix("\\["))
        #expect(out.contains("\\left( \\right."))
    }

    @Test("the attention formula from the report")
    func attention() {
        let raw = #"\operatorname {Attention} (Q, K, V) = \operatorname {softmax} (\frac {Q K ^ {T}}{\sqrt {d _ {k}}}) V \tag {1}"#
        #expect(EquationFixer.process(raw)
            == #"\operatorname{Attention}(Q,K,V)=\operatorname{softmax}(\frac{QK^{T}}{\sqrt{d_{k}}})V\tag{1}"#)
    }

    @Test("'<' gets a trailing space so it cannot fuse with a following letter")
    func lessThan() {
        #expect(EquationFixer.process("a<b") == "a< b")
    }

    @Test("equation_block merging uses an array and turns extra tags into labels")
    func combine() {
        let one = EquationFixer.combine(["a=b \\tag{1}", "c=d"])
        #expect(one == "\\begin{array}{l} a=b \\tag{1} \\\\ c=d \\\\ \\end{array}")
        let two = EquationFixer.combine(["a=b \\tag{1}", "c=d \\tag{2}"])
        #expect(two == "\\begin{array}{l} a=b (1) \\\\ c=d (2) \\\\ \\end{array}")
    }
}

@Suite("PostProcess")
struct PostProcessTests {

    typealias Box = LayoutParser.Box

    @Test("display math inside prose becomes inline, citations stay")
    func displayToInline() {
        let src = #"(B) \[ \begin{pmatrix}2&-1\\-1&2\end{pmatrix}. \] see \[1, 2\] and \[3-5\]"#
        let out = PostProcess.displayToInline(src)
        #expect(out.hasPrefix(#"(B) \( "#))
        #expect(out.contains(#"\[1, 2\]"#))
        #expect(out.contains(#"\[3-5\]"#))
    }

    @Test("macro spacing is restored inside inline math only")
    func macroSpacing() {
        #expect(PostProcess.fixMacroSpacing(#"abcdf \( a \timesX b \) \timesY"#)
            == #"abcdf \( a \times X b \) \timesY"#)
        #expect(PostProcess.fixMacroSpacing(#"\( \int x \)"#) == #"\( \int x \)"#)
        #expect(PostProcess.fixMacroSpacing(#"\( a \tox \)"#) == #"\( a \to x \)"#)
        // longer macro names are not touched
        #expect(PostProcess.fixMacroSpacing(#"\( \topology \)"#) == #"\( \topology \)"#)
    }

    @Test("underscores move out of the formula")
    func underscores() {
        #expect(PostProcess.moveUnderscoresOutside(#"xxx = \( \sigma ___ = \lambda \)"#)
            == #"xxx = \( \sigma \) ___ \( = \lambda \)"#)
        #expect(PostProcess.moveUnderscoresOutside(#"\( a_1 \)"#) == #"\( a_1 \)"#)
    }

    @Test("[Non-Text] placeholders are dropped")
    func placeholder() {
        let blocks = [
            RecognizedBlock(type: "text", box: Box(x1: 0, y1: 0, x2: 1, y2: 0.1), content: "[Non-Text]"),
            RecognizedBlock(type: "text", box: Box(x1: 0, y1: 0.2, x2: 1, y2: 0.3), content: "real"),
        ]
        #expect(PostProcess.pieces(from: blocks).map(\.text) == ["real\n"])
    }

    @Test("equations covered by an equation_block are merged")
    func equationBlock() {
        let blocks = [
            RecognizedBlock(type: "equation_block", box: Box(x1: 0.1, y1: 0.1, x2: 0.9, y2: 0.4), content: ""),
            RecognizedBlock(type: "equation", box: Box(x1: 0.1, y1: 0.1, x2: 0.9, y2: 0.2), content: "a = b"),
            RecognizedBlock(type: "equation", box: Box(x1: 0.1, y1: 0.25, x2: 0.9, y2: 0.4), content: "c = d"),
            RecognizedBlock(type: "equation", box: Box(x1: 0.1, y1: 0.7, x2: 0.9, y2: 0.8), content: "e = f"),
        ]
        let pieces = PostProcess.pieces(from: blocks)
        #expect(pieces.count == 2)
        #expect(pieces[0].text.contains("\\begin{array}{l}"))
        #expect(pieces[1].text.contains("e=f"))
    }

    @Test("a single equation inside an equation_block is not wrapped")
    func equationBlockSingle() {
        let blocks = [
            RecognizedBlock(type: "equation_block", box: Box(x1: 0.1, y1: 0.1, x2: 0.9, y2: 0.4), content: ""),
            RecognizedBlock(type: "equation", box: Box(x1: 0.1, y1: 0.1, x2: 0.9, y2: 0.4), content: "a = b"),
        ]
        let pieces = PostProcess.pieces(from: blocks)
        #expect(pieces.count == 1)
        #expect(!pieces[0].text.contains("array"))
    }

    @Test("titles clean math spacing")
    func title() {
        let blocks = [RecognizedBlock(
            type: "title", box: Box(x1: 0, y1: 0, x2: 1, y2: 0.05), content: #"On \( x ^ {2} \)"#
        )]
        let piece = PostProcess.pieces(from: blocks)[0]
        #expect(piece.text == #"On \(x^{2}\)"#)
    }

    @Test("paratext listed in skipTypes is dropped")
    func skip() {
        let blocks = [RecognizedBlock(type: "footer", box: Box(x1: 0, y1: 0.9, x2: 1, y2: 1), content: "12")]
        #expect(PostProcess.pieces(from: blocks, skipTypes: ["footer"]).isEmpty)
    }

    @Test("continuation pieces join with a space, or directly for Chinese")
    func join() {
        #expect(PostProcess.joinContinuation("end of page\n", "next") == "end of page next")
        #expect(PostProcess.joinContinuation("上一页\n", "下一页") == "上一页下一页")
    }

    @Test("assemble merges a mergePrev piece into the previous paragraph")
    func assembleMerge() {
        typealias P = MinerUKit.Session.Piece
        let md = MinerUKit.Session.assemble([
            P(kind: .body, text: "first half\n", isText: true),
            P(kind: .body, text: "![](x.png)\n"),
            P(kind: .body, text: "second half\n", isText: true, mergePrev: true),
        ])
        #expect(md.contains("first half second half"))
        #expect(md.contains("![](x.png)"))
    }
}

@Suite("LayoutParser (upstream rules)")
struct LayoutUpstreamTests {

    @Test("txt_contd_tgt marks a text block as continuing")
    func mergePrev() {
        let raw = """
        <|box_start|>100 100 400 200<|box_end|><|ref_start|>text<|ref_end|><|rotate_up|>
        <|box_start|>100 300 400 400<|box_end|><|ref_start|>text<|ref_end|><|rotate_up|>txt_contd_tgt
        """
        let blocks = LayoutParser.parse(raw)
        #expect(blocks.map(\.mergePrev) == [false, true])
    }

    @Test("unknown becomes image, inline_formula and strangers are skipped")
    func types() {
        let raw = """
        <|box_start|>100 100 400 200<|box_end|><|ref_start|>unknown<|ref_end|><|rotate_up|>
        <|box_start|>100 300 400 400<|box_end|><|ref_start|>inline_formula<|ref_end|><|rotate_up|>
        <|box_start|>100 500 400 600<|box_end|><|ref_start|>banana<|ref_end|><|rotate_up|>
        """
        #expect(LayoutParser.parse(raw).map(\.type) == ["image"])
    }

    @Test("near-identical boxes of the same type collapse, different types stay")
    func iou() {
        let raw = """
        <|box_start|>100 100 500 200<|box_end|><|ref_start|>text<|ref_end|><|rotate_up|>
        <|box_start|>102 100 500 200<|box_end|><|ref_start|>text<|ref_end|><|rotate_up|>
        <|box_start|>100 100 500 200<|box_end|><|ref_start|>title<|ref_end|><|rotate_up|>
        <|box_start|>100 100 500 200<|box_end|><|ref_start|>text<|ref_end|><|rotate_left|>
        """
        #expect(LayoutParser.parse(raw).count == 3)
    }

    @Test("text covered by a table is dropped, below the 90% threshold it stays")
    func tableInternal() {
        let raw = """
        <|box_start|>100 100 600 500<|box_end|><|ref_start|>table<|ref_end|><|rotate_up|>
        <|box_start|>110 110 590 200<|box_end|><|ref_start|>text<|ref_end|><|rotate_up|>
        <|box_start|>500 400 700 600<|box_end|><|ref_start|>text<|ref_end|><|rotate_up|>
        """
        #expect(LayoutParser.parse(raw).map(\.type) == ["table", "text"])
    }

    @Test("captions inside an image are dropped")
    func captionInsideImage() {
        let raw = """
        <|box_start|>100 100 600 500<|box_end|><|ref_start|>image<|ref_end|><|rotate_up|>
        <|box_start|>110 450 590 490<|box_end|><|ref_start|>image_caption<|ref_end|><|rotate_up|>
        <|box_start|>110 520 590 560<|box_end|><|ref_start|>image_caption<|ref_end|><|rotate_up|>
        """
        #expect(LayoutParser.parse(raw).count == 2)
    }

    @Test("reversed corners are normalized, out-of-grid boxes rejected")
    func bounds() {
        let raw = """
        <|box_start|>400 300 100 100<|box_end|><|ref_start|>text<|ref_end|><|rotate_up|>
        <|box_start|>100 100 1200 300<|box_end|><|ref_start|>text<|ref_end|><|rotate_up|>
        """
        let blocks = LayoutParser.parse(raw)
        #expect(blocks.count == 1)
        #expect(blocks[0].box == LayoutParser.Box(x1: 0.1, y1: 0.1, x2: 0.4, y2: 0.3))
    }

    @Test("list containers with children are detected")
    func listChildren() {
        let raw = """
        <|box_start|>100 100 900 500<|box_end|><|ref_start|>list<|ref_end|><|rotate_up|>
        <|box_start|>110 110 890 200<|box_end|><|ref_start|>text<|ref_end|><|rotate_up|>
        """
        let blocks = LayoutParser.parse(raw)
        #expect(LayoutParser.hasChildren(blocks[0], in: blocks))
        #expect(!LayoutParser.hasChildren(blocks[1], in: blocks))
    }

    @Test("rotation angles follow the upstream (PIL counter-clockwise) convention")
    func angles() {
        #expect(LayoutParser.Rotation.right.angle == 90)
        #expect(LayoutParser.Rotation.down.angle == 180)
        #expect(LayoutParser.Rotation.left.angle == 270)
    }
}

@Suite("Region preparation")
struct RegionTests {

    func image(_ w: Int, _ h: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8) = { _, _ in (0, 0, 0) }) -> CGImage {
        var data = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = fill(x, y)
                let o = (y * w + x) * 4
                data[o] = r; data[o + 1] = g; data[o + 2] = b; data[o + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        // draw so that image pixel (x, y) (top-left origin) lands on the 1x1 context
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return Array(px.prefix(3))
    }

    @Test("thin strips are padded to the maximum aspect ratio")
    func aspect() {
        let out = prepareRegion(image(3000, 40))
        #expect(out.width == 3000)
        #expect(out.height == 60)
    }

    @Test("tiny crops are enlarged to the minimum edge")
    func minEdge() {
        let out = prepareRegion(image(14, 14))
        #expect(out.width == 28 && out.height == 28)
    }

    @Test("normal crops pass through")
    func normal() {
        let out = prepareRegion(image(300, 200))
        #expect(out.width == 300 && out.height == 200)
    }

    @Test("crop has no padding by default")
    func crop() {
        let img = image(1000, 1000)
        let c = renderCrop(img, box: LayoutParser.Box(x1: 0.1, y1: 0.2, x2: 0.5, y2: 0.4))
        #expect(c?.width == 400 && c?.height == 200)
    }

    @Test("a quarter turn is counter-clockwise and swaps the dimensions")
    func rotate() throws {
        // 3x2 image: left column red, rest black.
        let img = image(3, 2) { x, _ in x == 0 ? (255, 0, 0) : (0, 0, 0) }
        let ccw = try img.rotated(by: 90)
        #expect(ccw.width == 2 && ccw.height == 3)
        // Counter-clockwise: the old left edge becomes the bottom edge.
        #expect(pixel(ccw, 0, 2) == [255, 0, 0])
        #expect(pixel(ccw, 0, 0) == [0, 0, 0])
        let cw = try img.rotated(by: 270)
        // Clockwise: the old left edge becomes the top edge.
        #expect(pixel(cw, 0, 0) == [255, 0, 0])
        let half = try img.rotated(by: 180)
        #expect(half.width == 3 && half.height == 2)
        #expect(pixel(half, 2, 0) == [255, 0, 0])
    }
}

@Suite("TextLayer CJK spacing")
struct TextLayerCJKTests {

    @Test("generated spaces between Chinese characters are removed")
    func generated() {
        #expect(TextLayer.removeGeneratedCJKSpaces("卫 星 技 术") == "卫星技术")
        #expect(TextLayer.removeGeneratedCJKSpaces("中 文 InSAR 技 术") == "中文 InSAR 技术")
        #expect(TextLayer.removeGeneratedCJKSpaces("中  文") == "中文")
    }

    @Test("spaces around Latin text and digits are kept")
    func latin() {
        #expect(TextLayer.removeGeneratedCJKSpaces("hello world") == "hello world")
        #expect(TextLayer.removeGeneratedCJKSpaces("第 3 章") == "第 3 章")
        #expect(TextLayer.removeGeneratedCJKSpaces("A 中") == "A 中")
    }

    @Test("closing and opening CJK punctuation count as CJK")
    func punctuation() {
        #expect(TextLayer.removeGeneratedCJKSpaces("你好 」 世界") == "你好」世界")
    }

    @Test("markdownBlocks applies it per line")
    func blocks() {
        #expect(TextLayer.markdownBlocks("卫 星\n技 术") == "卫星技术")
    }
}
