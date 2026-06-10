import Foundation

/// USD per million tokens for one model.
struct ModelPricing: Sendable, Equatable {
    let inputPerMTok: Double
    let outputPerMTok: Double
    /// Cache reads bill at 0.1× input; cache writes at 1.25× (5m TTL) / 2× (1h TTL).
    var cacheReadPerMTok: Double { inputPerMTok * 0.1 }
    var cacheWrite5mPerMTok: Double { inputPerMTok * 1.25 }
    var cacheWrite1hPerMTok: Double { inputPerMTok * 2.0 }
}

/// Static pricing snapshot (sourced from the Claude platform docs, 2026-06).
/// Claude Code's JSONL logs carry no `costUSD` in current versions, so Pulse
/// computes costs from token counts. Unknown models yield `nil` → the UI keeps
/// token counts but treats cost as an estimate over the priced subset.
enum PricingTable {
    /// Longest-prefix pricing match on the normalized model id.
    static func pricing(forClaudeModel rawID: String) -> ModelPricing? {
        let id = rawID.lowercased()
        let match = table
            .filter { id.contains($0.key) }
            .max { $0.key.count < $1.key.count }
        return match?.value
    }

    static func cost(
        model: String,
        input: Int64,
        output: Int64,
        cacheRead: Int64,
        cacheWrite5m: Int64,
        cacheWrite1h: Int64
    ) -> Double? {
        guard let pricing = pricing(forClaudeModel: model) else { return nil }
        let mTok = 1_000_000.0
        return Double(input) / mTok * pricing.inputPerMTok
            + Double(output) / mTok * pricing.outputPerMTok
            + Double(cacheRead) / mTok * pricing.cacheReadPerMTok
            + Double(cacheWrite5m) / mTok * pricing.cacheWrite5mPerMTok
            + Double(cacheWrite1h) / mTok * pricing.cacheWrite1hPerMTok
    }

    private static let table: [String: ModelPricing] = [
        "fable-5": .init(inputPerMTok: 10, outputPerMTok: 50),
        "opus-4-8": .init(inputPerMTok: 5, outputPerMTok: 25),
        "opus-4-7": .init(inputPerMTok: 5, outputPerMTok: 25),
        "opus-4-6": .init(inputPerMTok: 5, outputPerMTok: 25),
        "opus-4-5": .init(inputPerMTok: 5, outputPerMTok: 25),
        "opus-4-1": .init(inputPerMTok: 15, outputPerMTok: 75),
        // Base keys catch the dated legacy ids ("claude-opus-4-20250514");
        // longest-key matching keeps the specific entries above authoritative.
        "opus-4": .init(inputPerMTok: 15, outputPerMTok: 75),
        "sonnet-4-6": .init(inputPerMTok: 3, outputPerMTok: 15),
        "sonnet-4-5": .init(inputPerMTok: 3, outputPerMTok: 15),
        "sonnet-4": .init(inputPerMTok: 3, outputPerMTok: 15),
        "haiku-4-5": .init(inputPerMTok: 1, outputPerMTok: 5),
    ]
}
