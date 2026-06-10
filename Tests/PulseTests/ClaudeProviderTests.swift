import Foundation
import Testing
@testable import Pulse

// All fixtures below are fabricated: realistic shapes from
// docs/RESEARCH/claude.md with fake ids — never real tokens.

// MARK: - Credentials

@Suite("Claude credentials")
struct ClaudeCredentialsTests {
    private let fullJSON = Data(#"""
    {"claudeAiOauth":{
      "accessToken":"sk-ant-oat01-FAKE-FAKE-FAKE",
      "refreshToken":"sk-ant-ort01-FAKE-FAKE-FAKE",
      "expiresAt":1781055688177,
      "scopes":["user:inference","user:profile"],
      "subscriptionType":"max",
      "rateLimitTier":"default_claude_max_5x"}}
    """#.utf8)

    @Test func parsesAllFields() throws {
        let credentials = try ClaudeCredentials.parse(json: fullJSON)
        #expect(credentials.accessToken == "sk-ant-oat01-FAKE-FAKE-FAKE")
        #expect(credentials.expiresAt == 1_781_055_688_177)
        #expect(credentials.subscriptionType == "max")
        #expect(credentials.rateLimitTier == "default_claude_max_5x")
    }

    @Test func expiresAtIsEpochMilliseconds() throws {
        let credentials = try ClaudeCredentials.parse(json: fullJSON)
        // 1781055688177 ms ⇔ 1_781_055_688.177 s. A seconds (mis)reading would
        // place expiry in year ~58400 and never flip the second expectation.
        #expect(!credentials.isExpired(now: Date(timeIntervalSince1970: 1_781_055_687)))
        #expect(credentials.isExpired(now: Date(timeIntervalSince1970: 1_781_055_689)))
    }

    @Test func missingExpiryNeverExpires() {
        let credentials = ClaudeCredentials(accessToken: "x", expiresAt: nil)
        #expect(!credentials.isExpired(now: .distantFuture))
    }

    @Test func missingTokenIsNotLoggedIn() {
        do {
            _ = try ClaudeCredentials.parse(json: Data(#"{"claudeAiOauth":{"expiresAt":1}}"#.utf8))
            Issue.record("expected a throw")
        } catch let error as ProviderFetchError {
            guard case .notLoggedIn = error else {
                Issue.record("expected .notLoggedIn, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ProviderFetchError, got \(error)")
        }
    }

    @Test func malformedJSONIsParsingError() {
        do {
            _ = try ClaudeCredentials.parse(json: Data("not json at all".utf8))
            Issue.record("expected a throw")
        } catch let error as ProviderFetchError {
            guard case .parsing = error else {
                Issue.record("expected .parsing, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ProviderFetchError, got \(error)")
        }
    }

    @Test func planLabelMapping() {
        func label(_ type: String?, _ tier: String?) -> String? {
            ClaudeCredentials(
                accessToken: "x",
                expiresAt: nil,
                subscriptionType: type,
                rateLimitTier: tier
            ).planLabel
        }
        #expect(label("max", "default_claude_max_5x") == "Max 5×")
        #expect(label("max", "default_claude_max_20x") == "Max 20×")
        #expect(label("max", "DEFAULT_CLAUDE_MAX_5X") == "Max 5×")
        #expect(label("max", nil) == "Max")
        #expect(label("max", "default_claude_max") == "Max")
        #expect(label("pro", "default_claude_pro") == "Pro")
        #expect(label("team", nil) == "Team")
        #expect(label("enterprise", nil) == "Enterprise")
        #expect(label(nil, "default_claude_max_5x") == nil)
        #expect(label("", nil) == nil)
    }

    @Test func keychainProbeReportsMissingItem() async {
        // Promptless metadata-only lookup; a random service can never exist.
        let exists = await ClaudeCredentialsStore.keychainItemExists(
            service: "Pulse-Test-Nonexistent-\(UUID().uuidString)"
        )
        #expect(!exists)
    }
}

// MARK: - Usage endpoint

@Suite("Claude usage endpoint")
struct ClaudeUsageEndpointTests {
    private let responseJSON = Data(#"""
    {"five_hour":{"utilization":6.0,"resets_at":"2026-06-10T02:40:00.086425+00:00"},
     "seven_day":{"utilization":41.5,"resets_at":"2026-06-15T14:00:00+00:00"},
     "seven_day_oauth_apps":null,
     "seven_day_opus":{"utilization":12.5,"resets_at":null},
     "seven_day_sonnet":{"utilization":0.0,"resets_at":null},
     "seven_day_cowork":null,
     "tangelo":null,
     "iguana_necktie":null,
     "cinder_cove":null,
     "freshly_invented_window":{"utilization":3.25},
     "future_flag":"enabled",
     "iteration_count":7,
     "extra_usage":{"is_enabled":true,"monthly_limit":50,"used_credits":6,"utilization":12.0,"currency":"USD"}}
    """#.utf8)

    @Test func decodesWindowsTolerantly() throws {
        let response = try ClaudeUsageResponse.parse(responseJSON)

        #expect(response.windows["five_hour"]?.utilization == 6.0)
        #expect(response.windows["seven_day"]?.utilization == 41.5)
        #expect(response.windows["seven_day_opus"]?.utilization == 12.5)
        #expect(response.windows["seven_day_sonnet"]?.utilization == 0.0)

        // Null windows are simply absent; non-window values are ignored.
        #expect(response.windows["seven_day_oauth_apps"] == nil)
        #expect(response.windows["tangelo"] == nil)
        #expect(response.windows["future_flag"] == nil)
        #expect(response.windows["iteration_count"] == nil)
        // The pay-as-you-go block is not a rate-limit window even when enabled.
        #expect(response.windows["extra_usage"] == nil)
        // Unknown codenamed keys with the window shape are still captured.
        #expect(response.windows["freshly_invented_window"]?.utilization == 3.25)
        #expect(response.windows["freshly_invented_window"]?.resetsAt == nil)
    }

    @Test func parsesMicrosecondResetTimestamps() throws {
        let response = try ClaudeUsageResponse.parse(responseJSON)
        let resetsAt = try #require(response.windows["five_hour"]?.resetsAt)
        let wholeSecond = try #require(ClaudeISO8601().date(from: "2026-06-10T02:40:00Z"))
        #expect(abs(resetsAt.timeIntervalSince(wholeSecond) - 0.086) < 0.01)
        // The plain variant parses too.
        #expect(response.windows["seven_day"]?.resetsAt != nil)
    }

    @Test func iso8601VariantsAllParse() {
        let iso = ClaudeISO8601()
        #expect(iso.date(from: "2026-06-09T21:47:03.483Z") != nil)            // JSONL millis
        #expect(iso.date(from: "2026-06-10T02:40:00.086425+00:00") != nil)    // endpoint micros
        #expect(iso.date(from: "2026-06-15T14:00:00+00:00") != nil)           // no fraction
        #expect(iso.date(from: "2026-06-15T14:00:00.5Z") != nil)              // short fraction
        #expect(iso.date(from: "not a date") == nil)
        #expect(iso.date(from: "2026-06-15T14:00:00.Z") == nil)
    }

    @Test func mapsWindowsToGauges() throws {
        let response = try ClaudeUsageResponse.parse(responseJSON)
        let mapped = ClaudeUsageAPI.limitWindows(from: response)

        let primary = try #require(mapped.primary)
        #expect(primary.id == "five_hour")
        #expect(primary.title == "5-Hour Session")
        #expect(primary.systemImage == "clock")
        #expect(primary.utilization == 6.0)
        #expect(primary.windowDuration == TimeInterval(5 * 3600))
        #expect(primary.resetsAt != nil)

        let secondary = try #require(mapped.secondary)
        #expect(secondary.id == "seven_day")
        #expect(secondary.title == "Weekly Limit")
        #expect(secondary.systemImage == "calendar")
        #expect(secondary.windowDuration == TimeInterval(7 * 86400))

        // Opus carries signal (12.5%); Sonnet at 0% does not.
        #expect(mapped.extras.map(\.id) == ["seven_day_opus"])
        #expect(mapped.extras.first?.title == "Opus Weekly")
        #expect(mapped.extras.first?.systemImage == "sparkles")
        #expect(mapped.extras.first?.windowDuration == TimeInterval(7 * 86400))
        #expect(mapped.extras.first?.resetsAt == nil)
    }

    @Test func responseWithoutAnyWindowIsAParseError() {
        // A 2xx body carrying zero window-shaped values (all-null windows or
        // an error envelope) must not masquerade as "no limits exist" — the
        // store would blank the gauges over a schema hiccup.
        #expect(throws: ProviderFetchError.self) {
            _ = try ClaudeUsageResponse.parse(Data(#"{"five_hour":null,"seven_day":null}"#.utf8))
        }
        #expect(throws: ProviderFetchError.self) {
            _ = try ClaudeUsageResponse.parse(Data(#"{"error":{"type":"overloaded_error"}}"#.utf8))
        }
    }

    @Test func partiallyNullWindowsStillParse() throws {
        let response = try ClaudeUsageResponse.parse(
            Data(#"{"five_hour":{"utilization":3.0,"resets_at":null},"seven_day":null}"#.utf8)
        )
        let mapped = ClaudeUsageAPI.limitWindows(from: response)
        #expect(mapped.primary?.utilization == 3.0)
        #expect(mapped.secondary == nil)
        #expect(mapped.extras.isEmpty)
    }

    @Test func nonObjectTopLevelIsParsingError() {
        #expect(throws: ProviderFetchError.self) {
            try ClaudeUsageResponse.parse(Data("[1,2,3]".utf8))
        }
    }
}

// MARK: - Log lines

@Suite("Claude log lines")
struct ClaudeLogLineTests {
    /// Fabricated Claude Code session-log line (shape per docs/RESEARCH/claude.md §3b).
    private func usageLine(
        type: String = "assistant",
        timestamp: String = "2026-06-09T21:47:08.011Z",
        id: String? = "msg_01FAKEAAA",
        requestID: String? = "req_011FAKEAAA",
        model: String = "claude-fable-5",
        input: Int64 = 2,
        output: Int64 = 930,
        cacheRead: Int64 = 226_971,
        cacheTotal: Int64 = 970,
        breakdown: String? = #"{"ephemeral_5m_input_tokens":700,"ephemeral_1h_input_tokens":270}"#
    ) -> String {
        let idField = id.map { #""id":"\#($0)","# } ?? ""
        let requestField = requestID.map { #""requestId":"\#($0)","# } ?? ""
        let breakdownField = breakdown.map { #","cache_creation":\#($0)"# } ?? ""
        return #"{"parentUuid":"p-1","isSidechain":false,"cwd":"/tmp/proj","sessionId":"s-1","version":"2.1.170","type":"\#(type)","timestamp":"\#(timestamp)",\#(requestField)"uuid":"u-1","message":{\#(idField)"type":"message","role":"assistant","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheTotal)\#(breakdownField),"service_tier":"standard","inference_geo":"not_available"}}}"#
    }

    private func parse(_ line: String, timeZone: TimeZone = .current) -> ClaudeLogParser.Entry? {
        let formatter = ClaudeLogParser.localDayFormatter()
        formatter.timeZone = timeZone
        return ClaudeLogParser.parseLine(Substring(line), dayFormatter: formatter)
    }

    @Test func parsesAssistantUsageWithCacheBreakdown() throws {
        let entry = try #require(parse(usageLine()))
        #expect(entry.key == "msg_01FAKEAAA|req_011FAKEAAA")
        #expect(entry.model == "claude-fable-5")
        #expect(entry.input == 2)
        #expect(entry.output == 930)
        #expect(entry.cacheRead == 226_971)
        #expect(entry.cacheWrite5m == 700)
        #expect(entry.cacheWrite1h == 270)
        #expect(entry.outputForDedup == 930)
    }

    @Test func missingBreakdownTreatsAllWritesAsFiveMinute() throws {
        let entry = try #require(parse(usageLine(cacheTotal: 1350, breakdown: nil)))
        #expect(entry.cacheWrite5m == 1350)
        #expect(entry.cacheWrite1h == 0)
    }

    @Test func partialBreakdownDoesNotDoubleCount() throws {
        // Breakdown object present but with only the 1h key: the split is
        // authoritative — the flat total must not leak into the 5m bucket.
        let entry = try #require(parse(usageLine(
            cacheTotal: 970,
            breakdown: #"{"ephemeral_1h_input_tokens":970}"#
        )))
        #expect(entry.cacheWrite5m == 0)
        #expect(entry.cacheWrite1h == 970)
    }

    @Test func skipsSyntheticModel() {
        #expect(parse(usageLine(model: "<synthetic>", input: 0, output: 0)) == nil)
    }

    @Test func skipsNonAssistantEvenWithMarkers() {
        // Contains both `"assistant"` and `"usage"` markers but is a user record.
        let line = #"{"type":"user","mode":"assistant","note":"usage","timestamp":"2026-06-09T21:47:08.011Z"}"#
        #expect(parse(line) == nil)
        #expect(parse(usageLine(type: "user")) == nil)
    }

    @Test func skipsAssistantWithoutUsageOrTimestamp() {
        let noUsage = #"{"type":"assistant","timestamp":"2026-06-09T21:47:08.011Z","message":{"id":"m","model":"claude-fable-5"}}"#
        #expect(parse(noUsage) == nil)
        #expect(parse(usageLine(timestamp: "yesterday-ish")) == nil)
    }

    @Test func missingIDsDisableDedupKey() throws {
        #expect(try #require(parse(usageLine(id: nil))).key == nil)
        #expect(try #require(parse(usageLine(requestID: nil))).key == nil)
    }

    @Test func bucketsDaysInLocalTimezone() throws {
        // 23:30 UTC is already "tomorrow" two hours east of Greenwich…
        let east = try #require(TimeZone(secondsFromGMT: 2 * 3600))
        let eastEntry = try #require(parse(usageLine(timestamp: "2026-06-09T23:30:00.000Z"), timeZone: east))
        #expect(eastEntry.day == "2026-06-10")

        // …while 02:00 UTC is still "yesterday" seven hours west.
        let west = try #require(TimeZone(secondsFromGMT: -7 * 3600))
        let westEntry = try #require(parse(usageLine(timestamp: "2026-06-10T02:00:00.000Z"), timeZone: west))
        #expect(westEntry.day == "2026-06-09")

        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let utcEntry = try #require(parse(usageLine(timestamp: "2026-06-09T23:30:00.000Z"), timeZone: utc))
        #expect(utcEntry.day == "2026-06-09")
    }

    @Test func filePassPreDedupsKeyedLinesAndSkipsNoise() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-claude-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("session.jsonl")
        let lines = [
            usageLine(output: 3, breakdown: nil),                     // streamed partial
            usageLine(output: 930),                                   // final wins in-file
            usageLine(id: "msg_01OTHER", requestID: "req_011OTHER", output: 7),
            usageLine(model: "<synthetic>", input: 0, output: 0),     // skipped
            #"{"type":"user","mode":"assistant","note":"usage"}"#,    // skipped
            usageLine(id: nil, requestID: nil, output: 5),            // keyless, kept
            usageLine(id: nil, requestID: nil, output: 5),            // keyless, kept again
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let entries = try ClaudeLogParser.parseFile(url)
        #expect(entries.count == 4)
        #expect(entries.filter { $0.key == "msg_01FAKEAAA|req_011FAKEAAA" }.map(\.output) == [930])
        #expect(entries.filter { $0.key == nil }.count == 2)
    }

    @Test func unreadableFileThrowsForRetry() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-claude-missing-\(UUID().uuidString).jsonl")
        #expect(throws: (any Error).self) {
            try ClaudeLogParser.parseFile(missing)
        }
    }
}

// MARK: - Merge / rollup

@Suite("Claude merge")
struct ClaudeMergeTests {
    private let timeZone = TimeZone(secondsFromGMT: 2 * 3600)!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private var dayFormatter: DateFormatter {
        let formatter = ClaudeLogParser.localDayFormatter()
        formatter.timeZone = timeZone
        return formatter
    }

    /// Noon local time on 2026-06-10 (+02:00).
    private var now: Date {
        dayFormatter.date(from: "2026-06-10")!.addingTimeInterval(12 * 3600)
    }

    private func entry(
        key: String? = nil,
        day: String = "2026-06-10",
        model: String = "claude-opus-4-8",
        input: Int64 = 0,
        output: Int64 = 0,
        cacheRead: Int64 = 0,
        write5m: Int64 = 0,
        write1h: Int64 = 0
    ) -> ClaudeLogParser.Entry {
        ClaudeLogParser.Entry(
            key: key,
            day: day,
            model: model,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite5m: write5m,
            cacheWrite1h: write1h
        )
    }

    @Test func globalDedupKeepsMaxOutputAcrossFiles() throws {
        let partial = entry(key: "msg_x|req_x", input: 2, output: 3, write5m: 970)
        let final = entry(key: "msg_x|req_x", input: 2, output: 930, write5m: 970)

        // Order-independent: the larger output wins whichever file is seen first.
        for lists in [[[partial], [final]], [[final], [partial]]] {
            let tokens = try #require(ClaudeLogParser.rollUp(lists, calendar: calendar, now: now).tokens)
            #expect(tokens.today.output == 930)
            #expect(tokens.today.input == 2)          // counted once, not per duplicate
            #expect(tokens.today.cacheWrite == 970)
        }
    }

    @Test func keylessEntriesAllSurvive() throws {
        let a = entry(output: 10)
        let b = entry(output: 10)
        let tokens = try #require(ClaudeLogParser.rollUp([[a], [b]], calendar: calendar, now: now).tokens)
        #expect(tokens.today.output == 20)
    }

    @Test func bucketsTodayMonthAndDailySeries() throws {
        let entries = [
            entry(key: "a|1", day: "2026-06-10", input: 100),  // today
            entry(key: "b|2", day: "2026-06-08", input: 40),   // this month, in 7-day chart
            entry(key: "c|3", day: "2026-05-31", input: 7),    // previous month, off the chart
        ]
        let bundle = ClaudeLogParser.rollUp([entries], calendar: calendar, now: now)
        let tokens = try #require(bundle.tokens)

        #expect(tokens.today.input == 100)
        #expect(tokens.thisMonth.input == 140)

        #expect(bundle.dailyUsage.count == 7)
        #expect(bundle.dailyUsage.last?.date == calendar.startOfDay(for: now))
        #expect(bundle.dailyUsage.last?.totals.input == 100)
        let jun8 = calendar.startOfDay(for: try #require(dayFormatter.date(from: "2026-06-08")))
        #expect(bundle.dailyUsage.first { $0.date == jun8 }?.totals.input == 40)
        let chartStart = calendar.startOfDay(for: try #require(dayFormatter.date(from: "2026-06-04")))
        #expect(bundle.dailyUsage.first?.date == chartStart)
        // Days without usage render as zero bars.
        #expect(bundle.dailyUsage.first { $0.totals.isEmpty } != nil)
    }

    @Test func costsFollowThePricingTableSplit() throws {
        // opus-4-8: $5 in, $25 out, cache read 0.5, 5m write 6.25, 1h write 10 per MTok.
        let m: Int64 = 1_000_000
        let totals = ClaudeLogParser.totals(of: entry(input: m, output: m, cacheRead: m, write5m: m, write1h: m))
        #expect(abs((totals.costUSD ?? 0) - 46.75) < 0.0001)
        #expect(totals.cacheWrite == 2 * m)

        // Unknown models keep their token counts but carry no cost.
        let unknown = ClaudeLogParser.totals(of: entry(model: "mystery-model-9", input: 1000))
        #expect(unknown.costUSD == nil)
        #expect(unknown.input == 1000)
    }

    @Test func modelShareMathOverTheMonth() throws {
        let entries = [
            entry(key: "a|1", day: "2026-06-10", model: "claude-opus-4-8", input: 600_000, output: 150_000),
            // Dated alias and bare id merge into one display-name bucket.
            entry(key: "b|2", day: "2026-06-09", model: "claude-haiku-4-5-20251001", input: 100_000, output: 25_000),
            entry(key: "c|3", day: "2026-06-09", model: "claude-haiku-4-5", input: 100_000, output: 25_000),
        ]
        let tokens = try #require(ClaudeLogParser.rollUp([entries], calendar: calendar, now: now).tokens)

        #expect(tokens.modelBreakdown.map(\.model) == ["opus-4.8", "haiku-4.5"])
        #expect(abs(tokens.modelBreakdown[0].share - 75) < 0.001)
        #expect(abs(tokens.modelBreakdown[1].share - 25) < 0.001)
        // opus: 0.6M×$5 + 0.15M×$25 = $6.75; haiku: 0.2M×$1 + 0.05M×$5 = $0.45.
        #expect(abs((tokens.thisMonth.costUSD ?? 0) - 7.2) < 0.0001)
        #expect(tokens.showsCost)
    }

    @Test func previousMonthUsageDoesNotEnterShares() throws {
        let entries = [
            entry(key: "a|1", day: "2026-06-10", model: "claude-opus-4-8", input: 100),
            entry(key: "b|2", day: "2026-05-30", model: "claude-fable-5", input: 900_000),
        ]
        let tokens = try #require(ClaudeLogParser.rollUp([entries], calendar: calendar, now: now).tokens)
        #expect(tokens.modelBreakdown.map(\.model) == ["opus-4.8"])
        #expect(tokens.thisMonth.input == 100)
    }

    @Test func emptyAggregatesYieldNoReport() {
        let bundle = ClaudeLogParser.rollUp([], calendar: calendar, now: now)
        #expect(bundle.tokens == nil)
        #expect(bundle.dailyUsage.isEmpty)
    }
}

