import Foundation

/// USD per million tokens for one model.
///
/// Cache rates are derived, not stored, because both providers publish them as
/// fixed multiples of the base input price. Verified against every row of both
/// pricing pages on 2026-08-27: Anthropic writes are 1.25x (5m TTL) and 2x
/// (1h TTL) with reads at 0.1x, and OpenAI's published "cache writes" column is
/// 1.25x with "cached input" at 0.1x. Storing them separately would be four
/// more numbers to keep in sync for no accuracy gain.
struct ModelPricing: Sendable, Equatable {
    let inputPerMTok: Double
    let outputPerMTok: Double
    /// Cache reads bill at 0.1× input; cache writes at 1.25× (5m TTL) / 2× (1h TTL).
    var cacheReadPerMTok: Double { inputPerMTok * 0.1 }
    var cacheWrite5mPerMTok: Double { inputPerMTok * 1.25 }
    var cacheWrite1hPerMTok: Double { inputPerMTok * 2.0 }
}

/// Static pricing snapshot for the models Pulse sees locally.
///
/// **Sources, both fetched 2026-08-27:** Anthropic
/// `docs.claude.com/en/docs/about-claude/pricing`, OpenAI
/// `platform.openai.com/docs/pricing`.
///
/// Claude Code and Codex write no `costUSD` into their logs, so every figure
/// Pulse shows is computed here from token counts. A model missing from this
/// table yields `nil`, which the UI treats as "no cost data" rather than zero -
/// but it still silently drops that model out of any total, so a missing entry
/// under-reports rather than erroring. `PricingTests` guards against that by
/// asserting the models actually present in local logs are all priced.
///
/// Standard rates only. Batch (-50%), Fast mode, `inference_geo: "us"` (1.1x)
/// and OpenAI's long-context tier are deliberately not modelled: nothing in the
/// logs distinguishes them, so applying them would be guessing.
enum PricingTable {
    /// Longest-prefix pricing match on the normalized model id.
    ///
    /// `contains` rather than equality is load-bearing: it absorbs the dated
    /// suffixes Anthropic emits (`claude-haiku-4-5-20251001`) and the provider
    /// prefixes that arrive from routed traffic (`anthropic/claude-opus-5`),
    /// which would otherwise each need their own entry. Longest-key-wins keeps
    /// a specific entry authoritative over a shorter one that also matches, so
    /// `opus-4-1` never resolves through the broader `opus-4`.
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

    /// Keys are matched with `contains` against a lowercased model id, so they
    /// are written in the id's own dashed form (`sonnet-4-6`), never the dotted
    /// display form (`sonnet-4.6`) - the latter matches nothing.
    private static let table: [String: ModelPricing] = [
        // MARK: Anthropic
        // Frontier tier.
        "fable-5": .init(inputPerMTok: 10, outputPerMTok: 50),
        "mythos-5": .init(inputPerMTok: 10, outputPerMTok: 50),
        // Opus 4.5 through 5 share one price; 4.1 and 4 are the older, dearer tier.
        "opus-5": .init(inputPerMTok: 5, outputPerMTok: 25),
        "opus-4-8": .init(inputPerMTok: 5, outputPerMTok: 25),
        "opus-4-7": .init(inputPerMTok: 5, outputPerMTok: 25),
        "opus-4-6": .init(inputPerMTok: 5, outputPerMTok: 25),
        "opus-4-5": .init(inputPerMTok: 5, outputPerMTok: 25),
        "opus-4-1": .init(inputPerMTok: 15, outputPerMTok: 75),
        // Base keys catch the dated legacy ids ("claude-opus-4-20250514");
        // longest-key matching keeps the specific entries above authoritative.
        "opus-4": .init(inputPerMTok: 15, outputPerMTok: 75),
        // Sonnet 5 is cheaper than the 4.x line it replaced.
        "sonnet-5": .init(inputPerMTok: 2, outputPerMTok: 10),
        "sonnet-4-6": .init(inputPerMTok: 3, outputPerMTok: 15),
        "sonnet-4-5": .init(inputPerMTok: 3, outputPerMTok: 15),
        "sonnet-4": .init(inputPerMTok: 3, outputPerMTok: 15),
        "haiku-4-5": .init(inputPerMTok: 1, outputPerMTok: 5),
        "haiku-3-5": .init(inputPerMTok: 0.80, outputPerMTok: 4),

        // MARK: OpenAI
        // Short-context standard rates. The long-context tier costs 2x input
        // and up to 1.5x output, but the logs do not record which tier served a
        // request, so the short-context rate is the honest floor.
        "gpt-5-6-sol": .init(inputPerMTok: 4, outputPerMTok: 20),
        "gpt-5.6-sol": .init(inputPerMTok: 4, outputPerMTok: 20),
        "gpt-5-6-terra": .init(inputPerMTok: 2, outputPerMTok: 12),
        "gpt-5.6-terra": .init(inputPerMTok: 2, outputPerMTok: 12),
        "gpt-5-6-luna": .init(inputPerMTok: 0.20, outputPerMTok: 1.20),
        "gpt-5.6-luna": .init(inputPerMTok: 0.20, outputPerMTok: 1.20),
        "gpt-5-6-cyber": .init(inputPerMTok: 12.50, outputPerMTok: 75),
        "gpt-5.6-cyber": .init(inputPerMTok: 12.50, outputPerMTok: 75),
        // Codex CLI's own models. These dominate real Codex usage (gpt-5.3-codex
        // alone is 92% of local tokens), and the retired ones still appear in
        // historical logs, so they are priced from their model pages rather
        // than dropped when OpenAI removes them from the live pricing table.
        "gpt-5-3-codex": .init(inputPerMTok: 1.75, outputPerMTok: 14),
        "gpt-5.3-codex": .init(inputPerMTok: 1.75, outputPerMTok: 14),
        "gpt-5-2-codex": .init(inputPerMTok: 1.75, outputPerMTok: 14),
        "gpt-5.2-codex": .init(inputPerMTok: 1.75, outputPerMTok: 14),
        "gpt-5-1-codex": .init(inputPerMTok: 1.25, outputPerMTok: 10),
        "gpt-5.1-codex": .init(inputPerMTok: 1.25, outputPerMTok: 10),
        "gpt-5-codex": .init(inputPerMTok: 1.25, outputPerMTok: 10),
        // Flagship line, retired snapshots included for the same reason.
        "gpt-5-5": .init(inputPerMTok: 5, outputPerMTok: 30),
        "gpt-5.5": .init(inputPerMTok: 5, outputPerMTok: 30),
        "gpt-5-4-mini": .init(inputPerMTok: 0.75, outputPerMTok: 4.50),
        "gpt-5.4-mini": .init(inputPerMTok: 0.75, outputPerMTok: 4.50),
        "gpt-5-4": .init(inputPerMTok: 2.50, outputPerMTok: 15),
        "gpt-5.4": .init(inputPerMTok: 2.50, outputPerMTok: 15),
        // The ChatGPT-surface model.
        "chat-latest": .init(inputPerMTok: 5, outputPerMTok: 30),
    ]
}
