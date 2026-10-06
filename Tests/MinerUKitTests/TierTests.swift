import Testing
import Foundation
@testable import MinerUKit

@Suite("Tier")
struct TierTests {

    @Test("model usage matrix")
    func modelUsage() {
        #expect(!Tier.flash.usesModel)
        #expect(Tier.basic.usesModel)
        #expect(Tier.standard.usesModel)
        #expect(Tier.advanced.usesModel)
    }

    @Test("advanced renders finer and budgets more tokens")
    func advancedParams() {
        #expect(Tier.advanced.renderScale > Tier.standard.renderScale)
        #expect(Tier.advanced.recognitionMaxTokens > Tier.standard.recognitionMaxTokens)
        #expect(Tier.flash.renderScale == Tier.standard.renderScale)
    }

    @Test("raw values round-trip from CLI names")
    func roundTrip() {
        for name in ["flash", "basic", "standard", "advanced"] {
            #expect(Tier(rawValue: name) != nil, "tier \(name)")
        }
    }
}

@Suite("TextLayer paragraph reassembly")
struct TextLayerTests {

    @Test("wrapped latin lines merge with a space")
    func latinMerge() {
        let blocks = TextLayer.reassemble(["The dominant sequence", "transduction models are", "based on attention."])
        #expect(blocks == ["The dominant sequence transduction models are based on attention."])
    }

    @Test("hyphenated line breaks de-hyphenate")
    func dehyphenate() {
        let blocks = TextLayer.reassemble(["showed signifi-", "cantly better results"])
        #expect(blocks == ["showed significantly better results"])
    }

    @Test("CJK lines join without a space")
    func cjkJoin() {
        let blocks = TextLayer.reassemble(["注意力机制是", "序列建模的核心"])
        #expect(blocks == ["注意力机制是序列建模的核心"])
    }

    @Test("blank line splits paragraphs")
    func paragraphSplit() {
        let blocks = TextLayer.reassemble(["first para", "", "second para"])
        #expect(blocks == ["first para", "second para"])
    }

    @Test("list items stay separate blocks")
    func listSeparation() {
        let lines = [
            "contributions are:", "- Ashish proposed the idea", "- Noam wrote the code",
            "1. first", "2. second",
        ]
        let blocks = TextLayer.reassemble(lines)
        #expect(blocks == [
            "contributions are:",
            "- Ashish proposed the idea",
            "- Noam wrote the code",
            "1. first",
            "2. second",
        ])
    }

    @Test("list prefix detection")
    func listPrefixes() {
        for line in ["- item", "* item", "+ item", "• item", "1. item", "23) item", "a. item"] {
            #expect(TextLayer.isListStart(line), "should detect list: \(line)")
        }
        for line in ["regular text", "3 items or more", "-notaList (no space)"] {
            #expect(!TextLayer.isListStart(line), "should not detect list: \(line)")
        }
    }

    @Test("markdownBlocks joins paragraphs with blank lines")
    func markdownBlocks() {
        let out = TextLayer.markdownBlocks("line one\nline two\n\npara two")
        #expect(out == "line one line two\n\npara two")
    }

    @Test("text density gate")
    func density() {
        #expect(TextLayer.isTextDense("Attention is all you need, truly enough text here"))
        #expect(!TextLayer.isTextDense(nil))
        #expect(!TextLayer.isTextDense("12"))                       // page number
        #expect(!TextLayer.isTextDense("   \n  \t "))               // whitespace only
        #expect(!TextLayer.isTextDense(String(repeating: " ", count: 100)))
    }
}
