import Testing
@testable import MinerUKit

@Suite("LatexCleaner")
struct LatexCleanerTests {

    @Test("removes token spacing from recognizer output")
    func attention() {
        let raw = #"\operatorname {Attention} (Q, K, V) = \operatorname {softmax} (\frac {Q K ^ {T}}{\sqrt {d _ {k}}}) V \tag {1}"#
        #expect(LatexCleaner.clean(raw)
            == #"\operatorname{Attention}(Q,K,V)=\operatorname{softmax}(\frac{QK^{T}}{\sqrt{d_{k}}})V\tag{1}"#)
    }

    @Test("ffn example")
    func ffn() {
        let raw = #"\mathrm{FFN} (x) = \max (0, x W _ {1} + b _ {1}) W _ {2} + b _ {2} \tag {2}"#
        #expect(LatexCleaner.clean(raw)
            == #"\mathrm{FFN}(x)=\max(0,xW_{1}+b_{1})W_{2}+b_{2}\tag{2}"#)
    }

    @Test("keeps the space that separates a control word from a letter")
    func controlWordBoundary() {
        #expect(LatexCleaner.clean(#"\alpha x + \beta y"#) == #"\alpha x+\beta y"#)
        #expect(LatexCleaner.clean(#"\alpha ( x )"#) == #"\alpha(x)"#)
        #expect(LatexCleaner.clean(#"\sum _ {i = 1} ^ {n} \alpha _ i"#) == #"\sum_{i=1}^{n}\alpha_i"#)
    }

    @Test("keeps spaces inside text-mode arguments")
    func textMode() {
        #expect(LatexCleaner.clean(#"x \text {  if  } y > 0"#) == #"x\text{ if }y>0"#)
        #expect(LatexCleaner.clean(#"\text {a \{ b }"#) == #"\text{a \{ b }"#)
    }

    @Test("keeps control symbols intact")
    func controlSymbols() {
        #expect(LatexCleaner.clean(#"a \ b \, c \\ d \{ e \}"#) == #"a\ b\,c\\d\{e\}"#)
    }

    @Test("is idempotent")
    func idempotent() {
        let once = LatexCleaner.clean(#"\frac {a b}{\alpha c} \text { x y }"#)
        #expect(LatexCleaner.clean(once) == once)
    }

    @Test("leaves input with comments untouched")
    func comments() {
        let raw = "a + b % note\n + c"
        #expect(LatexCleaner.clean(raw) == raw)
    }

    @Test("cleans inline math spans in running text only")
    func inlineSpans() {
        let raw = #"where \( d _ {k} \) is the key size and \[ x ^ 2 \] holds, but a b stays."#
        #expect(LatexCleaner.cleanDelimitedMath(in: raw)
            == #"where \(d_{k}\) is the key size and \[x^2\] holds, but a b stays."#)
    }

    @Test("unterminated span is left as is")
    func unterminated() {
        let raw = #"cost \( a b"#
        #expect(LatexCleaner.cleanDelimitedMath(in: raw) == raw)
    }
}
