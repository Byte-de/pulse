import Foundation
import Testing
@testable import Pulse

// MARK: - Claude

@Suite("Claude parsing")
struct ClaudeParsingTests {
    private func line(
        id: String?,
        requestID: String?,
        model: String = "claude-opus-4-8",
        output: Int64,
        cache5m: Int64? = nil,
        cache1h: Int64? = nil,
        cacheTotal: Int64 = 0,
        type: String = "assistant"
    ) -> Substring {
        let breakdown = (cache5m != nil || cache1h != nil)
            ? #","cache_creation":{"ephemeral_5m_input_tokens":\#(cache5m ?? 0),"ephemeral_1h_input_tokens":\#(cache1h ?? 0)}"#
            : ""
        let idField = id.map { #""id":"\#($0)","# } ?? ""
        let requestField = requestID.map { #""requestId":"\#($0)","# } ?? ""
        return Substring(#"""
        {"type":"\#(type)","timestamp":"2026-06-09T21:47:03.483Z",\#(requestField)"message":{\#(idField)"model":"\#(model)","usage":{"input_tokens":100,"output_tokens":\#(output),"cache_read_input_tokens":50,"cache_creation_input_tokens":\#(cacheTotal)\#(breakdown)}}}
        """#)
    }

    @Test func parsesAssistantUsageLine() {
        let formatter = ClaudeLogParser.localDayFormatter()
        let entry = ClaudeLogParser.parseLine(
            line(id: "msg_1", requestID: "req_1", output: 930, cache5m: 970, cache1h: 10, cacheTotal: 980),
            dayFormatter: formatter
        )
        #expect(entry != nil)
        #expect(entry?.key == "msg_1|req_1")
        #expect(entry?.input == 100)
        #expect(entry?.output == 930)
        #expect(entry?.cacheRead == 50)
        #expect(entry?.cacheWrite5m == 970)
        #expect(entry?.cacheWrite1h == 10)
    }

    @Test func missingBreakdownBillsWritesAtFiveMinuteRate() {
        let entry = ClaudeLogParser.parseLine(
            line(id: "m", requestID: "r", output: 1, cacheTotal: 500),
            dayFormatter: ClaudeLogParser.localDayFormatter()
        )
        #expect(entry?.cacheWrite5m == 500)
        #expect(entry?.cacheWrite1h == 0)
    }

    @Test func skipsSyntheticAndNonAssistant() {
        let formatter = ClaudeLogParser.localDayFormatter()
        #expect(ClaudeLogParser.parseLine(
            line(id: "m", requestID: "r", model: "<synthetic>", output: 0),
            dayFormatter: formatter
        ) == nil)
        #expect(ClaudeLogParser.parseLine(
            line(id: "m", requestID: "r", output: 5, type: "user"),
            dayFormatter: formatter
        ) == nil)
    }

    @Test func dedupKeepsMaxOutputAcrossFiles() {
        let formatter = ClaudeLogParser.localDayFormatter()
        let partial = ClaudeLogParser.parseLine(line(id: "m", requestID: "r", output: 3), dayFormatter: formatter)!
        let final = ClaudeLogParser.parseLine(line(id: "m", requestID: "r", output: 930), dayFormatter: formatter)!
        let unrelated = ClaudeLogParser.parseLine(line(id: "m2", requestID: "r2", output: 7), dayFormatter: formatter)!

        let now = formatter.date(from: partial.day)!.addingTimeInterval(12 * 3600)
        let bundle = ClaudeLogParser.rollUp([[partial], [final, unrelated]], calendar: .current, now: now)
        // 930 (final wins over 3) + 7
        #expect(bundle.tokens?.thisMonth.output == 937)
    }

    @Test func keylessEntriesAreNeverDeduped() {
        let formatter = ClaudeLogParser.localDayFormatter()
        let a = ClaudeLogParser.parseLine(line(id: nil, requestID: nil, output: 10), dayFormatter: formatter)!
        let b = ClaudeLogParser.parseLine(line(id: nil, requestID: nil, output: 10), dayFormatter: formatter)!
        let now = formatter.date(from: a.day)!.addingTimeInterval(12 * 3600)
        let bundle = ClaudeLogParser.rollUp([[a], [b]], calendar: .current, now: now)
        #expect(bundle.tokens?.thisMonth.output == 20)
    }

    @Test func usageEndpointDecodesDynamicKeys() throws {
        let json = Data(#"""
        {"five_hour":{"utilization":42.0,"resets_at":"2026-06-10T02:40:00.086425+00:00"},
         "seven_day":{"utilization":28.0,"resets_at":null},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":0.0,"resets_at":null},
         "tangelo":null,
         "some_future_window":{"utilization":7.5,"resets_at":null},
         "extra_usage":{"is_enabled":false,"utilization":null}}
        """#.utf8)
        let response = try ClaudeUsageResponse.parse(json)
        #expect(response.windows["five_hour"]?.utilization == 42.0)
        #expect(response.windows["five_hour"]?.resetsAt != nil)
        #expect(response.windows["seven_day"]?.resetsAt == nil)
        #expect(response.windows["some_future_window"]?.utilization == 7.5)
        #expect(response.windows["extra_usage"] == nil)
        #expect(response.windows["tangelo"] == nil)

        let mapped = ClaudeUsageAPI.limitWindows(from: response)
        #expect(mapped.primary?.title == "5-Hour Session")
        #expect(mapped.secondary?.utilization == 28.0)
        #expect(mapped.extras.isEmpty) // sonnet at 0% carries no signal
    }

    @Test func planLabels() throws {
        let creds = try ClaudeCredentials.parse(json: Data(#"""
        {"claudeAiOauth":{"accessToken":"sk-test","expiresAt":1781055688177,
         "subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}
        """#.utf8))
        #expect(creds.planLabel == "Max 5×")
        #expect(creds.expiresAt == 1_781_055_688_177)
    }
}

// MARK: - Codex

@Suite("Codex parsing")
struct CodexParsingTests {
    private func tokenCountLine(input: Int64, cached: Int64, output: Int64, limits: Bool = false) -> String {
        let rateLimits = limits
            ? #","rate_limits":{"limit_id":"codex","primary":{"used_percent":85.0,"window_minutes":300,"resets_at":1765400000},"secondary":{"used_percent":17.0,"window_minutes":10080,"resets_at":1765900000}}"#
            : ""
        return #"{"timestamp":"2026-06-09T11:54:20.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"total_tokens":\#(input + output)}}\#(rateLimits)}}"#
    }

    private func turnContextLine(model: String) -> String {
        #"{"type":"turn_context","payload":{"model":"\#(model)","effort":"high"}}"#
    }

    private func makeSessionFile(lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-codex-\(UUID().uuidString)/2026/06/09")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-test.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func cumulativeDeltasAttributeToCurrentModel() throws {
        let url = try makeSessionFile(lines: [
            turnContextLine(model: "gpt-5.5"),
            tokenCountLine(input: 1000, cached: 600, output: 50),
            tokenCountLine(input: 3000, cached: 2000, output: 150),
            turnContextLine(model: "gpt-5.5-codex"),
            tokenCountLine(input: 6000, cached: 4500, output: 400),
        ])
        let aggregate = try CodexSessionParser.aggregate(file: url)

        let first = aggregate.models["gpt-5.5"]
        #expect(first?.input == 3000) // 1000 + 2000 cumulative delta
        #expect(first?.cached == 2000)
        #expect(first?.output == 150)

        let second = aggregate.models["gpt-5.5-codex"]
        #expect(second?.input == 3000) // 6000 − 3000
        #expect(second?.cached == 2500)
        #expect(second?.output == 250)

        #expect(aggregate.dayKey == "2026-06-09")
    }

    @Test func rateLimitSnapshotParsedFromSessionLines() throws {
        let url = try makeSessionFile(lines: [
            tokenCountLine(input: 100, cached: 0, output: 10, limits: true)
        ])
        let aggregate = try CodexSessionParser.aggregate(file: url)
        #expect(aggregate.rateLimits?.primaryUsedPercent == 85.0)
        #expect(aggregate.rateLimits?.primaryWindowMinutes == 300)
        #expect(aggregate.rateLimits?.secondaryUsedPercent == 17.0)
        #expect(aggregate.rateLimits?.primaryResetsAtEpoch == 1_765_400_000)
    }

    @Test func displayMappingSubtractsCachedFromInput() {
        let totals = CodexSessionParser.displayTotals(.init(input: 5000, cached: 4200, output: 300))
        #expect(totals.input == 800)
        #expect(totals.cacheRead == 4200)
        #expect(totals.output == 300)
        #expect(totals.costUSD == nil)
    }

    @Test func whamResponseDecodes() throws {
        let json = Data(#"""
        {"plan_type":"plus",
         "rate_limit":{
           "primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_after_seconds":9960},
           "secondary_window":{"used_percent":"28","limit_window_seconds":604800,"reset_at":1765900000}},
         "credits":{"has_credits":true,"unlimited":false,"balance":"1250"}}
        """#.utf8)
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: json)
        let now = Date(timeIntervalSince1970: 1_765_000_000)
        let windows = CodexUsageAPI.limitWindows(from: response, now: now)
        #expect(windows.primary?.utilization == 42)
        #expect(windows.primary?.windowDuration == 18000)
        #expect(windows.primary?.resetsAt == now.addingTimeInterval(9960))
        #expect(windows.secondary?.utilization == 28) // string-typed percent tolerated
        #expect(windows.secondary?.resetsAt == Date(timeIntervalSince1970: 1_765_900_000))
        #expect(CodexUsageAPI.creditsNote(from: response) == "Credits: 1250")
    }

    @Test func planClaimFromJWT() {
        func base64URL(_ string: String) -> String {
            Data(string.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_plan_type":"plus"},"email":"test@example.com"}"#
        let jwt = "\(base64URL(#"{"alg":"none"}"#)).\(base64URL(payload)).sig"
        let auth = CodexAuth(authMode: "chatgpt", accessToken: jwt, idToken: jwt, accountID: "acct")
        #expect(auth.plan == "Plus")
        #expect(auth.accountLabel == "te…@example.com")
    }
}

// MARK: - Cursor

@Suite("Cursor parsing")
struct CursorParsingTests {
    @Test func cookieComposition() {
        let cookie = CursorAuth.cookieHeader(sub: "auth0|user_123", accessToken: "tok.abc")
        #expect(cookie == "WorkosCursorSessionToken=auth0|user_123%3A%3Atok.abc")
    }

    @Test func flexibleScalarsAcceptStringsAndNumbers() throws {
        struct Probe: Decodable {
            var a: StringOrInt64
            var b: StringOrInt64
            var c: StringOrDouble
        }
        let probe = try JSONDecoder().decode(
            Probe.self,
            from: Data(#"{"a":"12345","b":678,"c":"3.5"}"#.utf8)
        )
        #expect(probe.a.value == 12345)
        #expect(probe.b.value == 678)
        #expect(probe.c.value == 3.5)
    }

    @Test func summaryPercentPrecedence() throws {
        func summary(_ plan: String) throws -> CursorUsageSummary {
            try JSONDecoder().decode(
                CursorUsageSummary.self,
                from: Data(#"{"individualUsage":{"plan":\#(plan)}}"#.utf8)
            )
        }
        #expect(try summary(#"{"totalPercentUsed":61.5,"autoPercentUsed":10}"#).planPercentUsed == 61.5)
        #expect(try summary(#"{"autoPercentUsed":10,"apiPercentUsed":30}"#).planPercentUsed == 20)
        #expect(try summary(#"{"apiPercentUsed":12}"#).planPercentUsed == 12)
        #expect(try summary(#"{"used":"5000","limit":"20000"}"#).planPercentUsed == 25)
        #expect(try summary(#"{}"#).planPercentUsed == nil)
    }

    @Test func legacyGaugeFallback() throws {
        let legacy = try JSONDecoder().decode(
            CursorLegacyUsage.self,
            from: Data(#"{"gpt-4":{"numRequests":150,"maxRequestUsage":500},"startOfMonth":"2026-06-01T00:00:00.000Z"}"#.utf8)
        )
        let window = CursorProvider.planWindow(summary: nil, legacy: legacy, invoice: nil, calendar: .current)
        #expect(window?.utilization == 30)
        #expect(window?.detail == "150 of 500 requests")
        #expect(window?.periodStart != nil)
        #expect(window?.resetsAt != nil)
    }

    @Test func aggregatedTokensWithStringCounts() throws {
        let aggregated = try JSONDecoder().decode(
            CursorAggregatedUsage.self,
            from: Data(#"""
            {"aggregations":[
              {"modelIntent":"claude-4.5-opus","inputTokens":"1000","outputTokens":"200",
               "cacheWriteTokens":"50","cacheReadTokens":"3000","totalCents":150.0},
              {"modelIntent":"gpt-5","inputTokens":"500","outputTokens":"100",
               "cacheWriteTokens":"0","cacheReadTokens":"0","totalCents":25.5}]}
            """#.utf8)
        )
        let report = CursorProvider.tokenReport(aggregated: aggregated, events: nil, calendar: .current, now: .now)
        #expect(report?.thisMonth.input == 1500)
        #expect(report?.thisMonth.cacheRead == 3000)
        #expect(report?.thisMonth.costUSD == 1.755)
        // Cursor's id shape ("claude-4.5-opus") must pass through unmangled.
        #expect(report?.modelBreakdown.first?.model == "claude-4.5-opus")
        #expect(ModelNames.display("claude-opus-4-8") == "opus-4.8")
        #expect(report?.showsCost == true)
    }

    @Test func spendWindowMath() throws {
        let hardLimit = try JSONDecoder().decode(CursorHardLimit.self, from: Data(#"{"hardLimit":125}"#.utf8))
        let invoice = try JSONDecoder().decode(
            CursorMonthlyInvoice.self,
            from: Data(#"{"periodStartMs":"1764547200000","periodEndMs":"1767225600000","items":[{"cents":1240,"description":"usage"},{"cents":-500,"description":"credit"}]}"#.utf8)
        )
        let window = CursorProvider.spendWindow(summary: nil, hardLimit: hardLimit, invoice: invoice)
        #expect(window != nil)
        #expect(abs(window!.utilization - (12.40 / 125 * 100)) < 0.001)
        #expect(window?.detail == "$12.40 of $125.00")
    }

    @Test func jsonOnlyDecodingRejectsSPAHTML() {
        let html = Data("<!doctype html><html>…</html>".utf8)
        #expect(CursorAPI.decodeJSONOnly(CursorHardLimit.self, from: html) == nil)
        let json = Data(#"{"hardLimit":50}"#.utf8)
        #expect(CursorAPI.decodeJSONOnly(CursorHardLimit.self, from: json)?.hardLimit?.value == 50)
    }
}

// Gemini parsing/probe/refresh coverage lives in GeminiProviderTests.swift
// alongside the transport-injectable engine it tests.
