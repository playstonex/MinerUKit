import Foundation
import MLX
import MLXLMCommon

/// Port of MinerU's vLLM NoRepeatNGram logits processor: bans the token that
/// would complete an already-generated n-gram. This is the mechanism that keeps
/// the 1.2B model from falling into repetition loops on recognition passes.
struct NoRepeatNGramProcessor: LogitProcessor {
    let ngramSize: Int
    private var tokens: [Int] = []
    private var nextTokens: [[Int]: [Int]] = [:]

    init(ngramSize: Int) {
        self.ngramSize = ngramSize
    }

    mutating func prompt(_ prompt: MLXArray) {}

    mutating func didSample(token: MLXArray) {
        register(token.item(Int.self))
    }

    /// Pure state machine, separated from MLXArray so it is testable without
    /// a Metal device.
    mutating func register(_ token: Int) {
        if ngramSize > 1, !tokens.isEmpty {
            let prefix = Array(tokens.suffix(ngramSize - 1))
            nextTokens[prefix, default: []].append(token)
        }
        tokens.append(token)
    }

    /// Tokens banned at the current position (would complete a seen n-gram).
    func bannedTokens() -> [Int]? {
        guard ngramSize > 0, tokens.count >= ngramSize else { return nil }
        let prefix = Array(tokens.suffix(ngramSize - 1))
        guard let banned = nextTokens[prefix], !banned.isEmpty else { return nil }
        return banned
    }

    func process(logits: MLXArray) -> MLXArray {
        guard let banned = bannedTokens() else { return logits }
        var result = logits
        let ids = MLXArray(banned.map { Int32($0) }, [banned.count])
        result[ids] = MLXArray(-Float.infinity)
        return result
    }
}
