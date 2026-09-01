import Foundation
import Testing

@testable import Pulse

/// Costs are computed locally from token counts, because neither Claude Code
/// nor Codex writes a cost into its logs. A model missing from the table
/// contributes **zero** to every total rather than raising, so an omission
/// under-reports silently - which is exactly what happened before this suite
/// existed, with 47% of real local tokens unpriced.
@Suite("Model pricing")
struct ModelPricingTests {
    /// Every model id seen in real logs, in the form the parser stores it.
    /// Dated suffixes and provider prefixes are deliberately included: both
    /// arrive in practice and both must resolve through `contains` matching.
    private static let realWorldIDs = [
        "claude-opus-5",
        "claude-opus-4-8",
        "claude-opus-4-7",
        "claude-opus-4-6",
        "claude-sonnet-5",
        "claude-sonnet-4-6",
        "claude-fable-5",
        "claude-haiku-4-5-20251001",
        "anthropic/claude-opus-5",
        "anthropic/claude-sonnet-5",
        "gpt-5.6-sol",
        "gpt-5.3-codex",
    ]

    @Test(arguments: realWorldIDs)
    func everyModelSeenInRealLogsIsPriced(id: String) {
        #expect(
            PricingTable.pricing(forClaudeModel: id) != nil,
            "\(id) has no price, so it silently contributes $0 to every total"
        )
    }

    /// Anthropic publishes cache rates as fixed multiples of base input, and
    /// `ModelPricing` derives rather than stores them. Verified against every
    /// row of the pricing page on 2026-08-27.
    @Test func cacheMultipliersMatchThePublishedRates() {
        let opus5 = ModelPricing(inputPerMTok: 5, outputPerMTok: 25)
        #expect(opus5.cacheWrite5mPerMTok == 6.25)
        #expect(opus5.cacheWrite1hPerMTok == 10)
        #expect(opus5.cacheReadPerMTok == 0.5)

        let sonnet5 = ModelPricing(inputPerMTok: 2, outputPerMTok: 10)
        #expect(sonnet5.cacheWrite5mPerMTok == 2.5)
        #expect(sonnet5.cacheWrite1hPerMTok == 4)
        #expect(sonnet5.cacheReadPerMTok == 0.2)

        let haiku = ModelPricing(inputPerMTok: 1, outputPerMTok: 5)
        #expect(haiku.cacheWrite5mPerMTok == 1.25)
        #expect(haiku.cacheWrite1hPerMTok == 2)
        #expect(haiku.cacheReadPerMTok == 0.1)
    }

    /// Base rates, spot-checked against the published tables. These are the
    /// numbers every dollar figure in the app derives from, so a typo here is
    /// invisible until someone reconciles against a real bill.
    @Test func baseRatesMatchThePublishedTables() {
        func rate(_ id: String) -> (Double, Double)? {
            PricingTable.pricing(forClaudeModel: id).map { ($0.inputPerMTok, $0.outputPerMTok) }
        }
        #expect(rate("claude-opus-5")! == (5, 25))
        #expect(rate("claude-sonnet-5")! == (2, 10), "Sonnet 5 is cheaper than the 4.x line")
        #expect(rate("claude-sonnet-4-6")! == (3, 15))
        #expect(rate("claude-fable-5")! == (10, 50))
        #expect(rate("claude-haiku-4-5")! == (1, 5))
        #expect(rate("claude-opus-4-1")! == (15, 75), "the older Opus tier is dearer")
        #expect(rate("gpt-5.6-sol")! == (4, 20))
        #expect(rate("gpt-5.3-codex")! == (1.75, 14))
    }

    /// Longest-key-wins, or `opus-4-1` resolves through the broader `opus-4`
    /// entry and is billed at the wrong tier. Both keys exist and both match.
    @Test func longestKeyWinsOverAShorterMatch() {
        let opus41 = PricingTable.pricing(forClaudeModel: "claude-opus-4-1")
        let opus4 = PricingTable.pricing(forClaudeModel: "claude-opus-4-20250514")
        #expect(opus41?.inputPerMTok == 15)
        #expect(opus4?.inputPerMTok == 15)

        // The dangerous direction: a specific key must not lose to a general one.
        let opus46 = PricingTable.pricing(forClaudeModel: "claude-opus-4-6")
        #expect(opus46?.inputPerMTok == 5, "opus-4-6 must not resolve through opus-4")
    }

    /// The table is keyed in the dashed id form. The UI's display form is
    /// dotted, and `contains` will not match it - so pricing a display name
    /// returns nil and silently costs nothing. This pins the trap: if a future
    /// change makes the display form resolve, the mismatch has been fixed and
    /// this expectation should be revisited deliberately.
    @Test func displayNamesDoNotResolveAndMustNotBePriced() {
        #expect(ModelNames.display("claude-haiku-4-5-20251001") == "haiku-4.5")
        #expect(
            PricingTable.pricing(forClaudeModel: "haiku-4.5") == nil,
            "dotted display names are not table keys; price the raw id instead"
        )
        // The raw id, which is what the parser actually stores, does resolve.
        #expect(PricingTable.pricing(forClaudeModel: "claude-haiku-4-5-20251001") != nil)
    }

    /// An unknown model must yield nil, never a zero cost that would look like
    /// a real, free request.
    @Test func unknownModelsYieldNoCostRatherThanZero() {
        #expect(PricingTable.pricing(forClaudeModel: "some-model-we-never-saw") == nil)
        #expect(
            PricingTable.cost(
                model: "some-model-we-never-saw",
                input: 1_000_000, output: 1_000_000,
                cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0
            ) == nil
        )
    }

    /// A worked example straight from Anthropic's own docs, so the arithmetic
    /// is checked against a number we did not invent: 50k input + 15k output on
    /// Opus 5 is $0.625, and with 40k of the input served from cache, $0.445.
    @Test func matchesAnthropicsWorkedExample() throws {
        let plain = try #require(PricingTable.cost(
            model: "claude-opus-5",
            input: 50_000, output: 15_000,
            cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0
        ))
        #expect(abs(plain - 0.625) < 0.0001, "0.25 input + 0.375 output")

        let cached = try #require(PricingTable.cost(
            model: "claude-opus-5",
            input: 10_000, output: 15_000,
            cacheRead: 40_000, cacheWrite5m: 0, cacheWrite1h: 0
        ))
        #expect(abs(cached - 0.445) < 0.0001, "0.05 input + 0.02 cache read + 0.375 output")
    }
}
