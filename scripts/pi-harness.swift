// Assertions for the pi harness parser (PiLogParser) and for the token card's
// "hide an all-zero sub-agent row" gate. Compiled against the real sources by
// scripts/verify-pi-tokens.sh, which also plants known defects and requires
// each to break at least one check here. Prints "ALL PASS" only when every
// check holds.
//
// Fixtures are fabricated in the *shape* verified on 2026-09-01 against the
// live ~/.pi/agent/sessions tree (40 files, 1,420 message records) — never real
// session content. An optional read-only pass over the live tree at the end
// only prints totals; it asserts nothing machine-specific.

import Foundation

var failures: [String] = []

@MainActor
func check(_ condition: Bool, _ label: String) {
    if !condition { failures.append(label) }
}

@MainActor
func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    if lhs != rhs { failures.append("\(label): got \(lhs), expected \(rhs)") }
}

// MARK: - Fixtures

let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pulse-pi-harness-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

struct Turn {
    var id: String
    var provider: String
    var model: String = "claude-opus-5"
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var cacheWrite1h: Int64 = 0
    var timestamp: String = "2026-06-18T10:00:00.000Z"
}

/// Writes a pi session file: one `session` record, then one `message` record
/// per turn, exactly as pi lays them out.
func writeSession(id: String, cwd: String, turns: [Turn], secret: String = "PROMPT-TEXT") -> URL {
    var lines: [String] = []
    let session: [String: Any] = [
        "type": "session", "version": 3, "id": id,
        "timestamp": "2026-06-18T09:59:00.000Z", "cwd": cwd,
    ]
    lines.append(String(decoding: try! JSONSerialization.data(withJSONObject: session), as: UTF8.self))
    // A user turn carries prompt text and no usage: it must never be decoded.
    let user: [String: Any] = [
        "type": "message", "id": "u1", "parentId": NSNull(),
        "timestamp": "2026-06-18T09:59:30.000Z",
        "message": ["role": "user", "content": [["type": "text", "text": secret]]],
    ]
    lines.append(String(decoding: try! JSONSerialization.data(withJSONObject: user), as: UTF8.self))
    for turn in turns {
        let message: [String: Any] = [
            "type": "message", "id": turn.id, "parentId": "u1", "timestamp": turn.timestamp,
            "message": [
                "role": "assistant",
                "api": "anthropic-messages",
                "provider": turn.provider,
                "model": turn.model,
                "content": [["type": "text", "text": secret]],
                "usage": [
                    "input": turn.input, "output": turn.output,
                    "cacheRead": turn.cacheRead, "cacheWrite": turn.cacheWrite,
                    "cacheWrite1h": turn.cacheWrite1h,
                    "totalTokens": turn.input + turn.output + turn.cacheRead + turn.cacheWrite,
                    "cost": ["input": 1.0, "output": 2.0, "total": 3.0],
                ] as [String: Any],
            ] as [String: Any],
        ]
        lines.append(String(decoding: try! JSONSerialization.data(withJSONObject: message), as: UTF8.self))
    }
    let dir = workDir.appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "-"))
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("2026-06-18T09-59-00-000Z_\(id).jsonl")
    try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

// MARK: - Checks

@MainActor
func run() async {
    // 1. Which pi provider keys can name a Claude account at all. A key that
    //    is not a first-party Anthropic subscription must be rejected here:
    //    folding an OpenAI- or Vertex-billed turn into a Claude tab bills the
    //    wrong account entirely. Note NO ordinal meaning is assigned - which
    //    account `anthropic-2` is gets resolved against Anthropic, because
    //    assuming the order was wrong on the first machine it met.
    check(PiAccountResolver.isAnthropicKey("anthropic"), "anthropic is an account key")
    check(PiAccountResolver.isAnthropicKey("anthropic-2"), "anthropic-2 is an account key")
    check(PiAccountResolver.isAnthropicKey("anthropic-10"), "anthropic-10 is an account key")
    check(!PiAccountResolver.isAnthropicKey("openai-codex"), "openai-codex is not")
    check(!PiAccountResolver.isAnthropicKey("openai-codex-2"), "openai-codex-2 is not")
    check(!PiAccountResolver.isAnthropicKey("anthropic-vertex"), "anthropic-vertex is not")

    // 2. One session billing two Anthropic accounts plus one OpenAI turn.
    let cwd = "/tmp/pulse-pi-fixture/alpha"
    _ = writeSession(id: "sess-a", cwd: cwd, turns: [
        Turn(id: "a1", provider: "anthropic", input: 10, output: 5, cacheRead: 100, cacheWrite: 1000, cacheWrite1h: 400),
        Turn(id: "a2", provider: "anthropic-2", input: 7, output: 3),
        Turn(id: "a3", provider: "openai-codex", input: 999, output: 999),
    ])

    let parsed = try! PiLogParser.parseSession(
        FileManager.default.enumeratedPiFile(in: workDir, named: "sess-a")
    )
    checkEqual(Set(parsed.byAccount.keys), Set(["anthropic", "anthropic-2"]), "session splits by pi provider key")

    guard let one = parsed.byAccount["anthropic"], let two = parsed.byAccount["anthropic-2"] else {
        failures.append("missing account slice"); return
    }
    checkEqual(one.entries.count, 1, "anthropic turn count")
    checkEqual(two.entries.count, 1, "anthropic-2 turn count")
    checkEqual(one.entries.first?.input, 10, "anthropic input")
    checkEqual(one.entries.first?.cacheRead, 100, "anthropic cacheRead")
    // pi's `cacheWrite` is the TOTAL cache creation and `cacheWrite1h` is the
    // subset written at the 1h TTL (verified in pi's anthropic-messages
    // adapter: cacheWrite = cache_creation_input_tokens,
    // cacheWrite1h = cache_creation.ephemeral_1h_input_tokens). Booking both in
    // full would inflate cache-write tokens by the 1h slice and price it twice.
    checkEqual(one.entries.first?.cacheWrite5m, 600, "cacheWrite 5m = total - 1h")
    checkEqual(one.entries.first?.cacheWrite1h, 400, "cacheWrite 1h")
    checkEqual(one.projectPath, cwd, "cwd comes from the session record")
    checkEqual(one.projectKey, cwd, "project key is the cwd, matching jcode's grouping")
    checkEqual(one.isSubAgent, false, "pi sessions are never sub-agents")
    check(one.sessionID.hasSuffix("#anthropic"), "two-account session ids are suffixed")

    // 2b. A turn that billed nothing is not a session. pi records usage for
    //     aborted/failed calls (12 all-zero assistant records on this machine,
    //     2026-09-01); keeping them would add zero-token rows to the breakdown
    //     for an account that never successfully ran anything.
    _ = writeSession(id: "sess-zero", cwd: "/tmp/pulse-pi-fixture/gamma", turns: [
        Turn(id: "z1", provider: "anthropic"),
    ])
    let zero = try! PiLogParser.parseSession(
        FileManager.default.enumeratedPiFile(in: workDir, named: "sess-zero")
    )
    checkEqual(zero.byAccount.count, 0, "a session whose every turn billed zero yields no slice")

    // 3. Nothing the user typed reaches the cache. The aggregate is persisted
    //    verbatim by FileAggregationCache, so its encoding is the real test.
    let encoded = String(decoding: try! JSONEncoder().encode(parsed), as: UTF8.self)
    check(!encoded.contains("PROMPT-TEXT"), "conversation text never enters the cached aggregate")

    // 4. A repeated 8-hex record id in a DIFFERENT session must not dedup away.
    //    pi ids are unique per file only, so an un-namespaced key silently
    //    deletes a whole turn's tokens from the totals.
    _ = writeSession(id: "sess-b", cwd: "/tmp/pulse-pi-fixture/beta", turns: [
        Turn(id: "a1", provider: "anthropic", input: 1000, output: 500),
    ])
    let other = try! PiLogParser.parseSession(
        FileManager.default.enumeratedPiFile(in: workDir, named: "sess-b")
    )
    let bundle = ClaudeLogParser.rollUp(
        sessions: [one, two, other.byAccount["anthropic"]].compactMap { $0 },
        calendar: Calendar.current,
        now: ClaudeISO8601().date(from: "2026-06-18T12:00:00.000Z")!
    )
    checkEqual(bundle.tokens?.today.input, 1017, "collided ids across sessions both count")

    // 5. pi has no sub-agents, so the card's sub-agent rows must not render.
    checkEqual(bundle.tokens?.todaySubAgent, TokenTotals.zero, "pi contributes no sub-agent usage")
    checkEqual(bundle.tokens?.hasSubAgentUsage, false, "all-zero sub-agent slice is hidden")
    check(!TokenUsageReport.isSubAgentSliceVisible(TokenTotals.zero), "zero slice is not visible")
    var priced = TokenTotals.zero
    priced.costUSD = 0
    check(!TokenUsageReport.isSubAgentSliceVisible(priced), "zero slice with zero cost is not visible")
    var real = TokenTotals.zero
    real.output = 1
    check(TokenUsageReport.isSubAgentSliceVisible(real), "non-zero slice IS visible")

    // 6. Live tree, read-only: prints only, so the harness stays machine-independent.
    //    `PULSE_PI_SESSIONS_ROOT` points it at a frozen snapshot instead, which
    //    is the only way to compare its totals with an independent count: the
    //    live tree is being appended to while the comparison runs.
    let live = ProcessInfo.processInfo.environment["PULSE_PI_SESSIONS_ROOT"].map(URL.init(fileURLWithPath:))
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/sessions")
    if FileManager.default.fileExists(atPath: live.path) {
        // Scratch cache name, deleted after the pass: the harness must never
        // touch the app's real cache, and must not litter the cache directory
        // with one file per run either.
        let cacheName = "pi-harness-scratch-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(
                at: AppPaths.cacheDirectory.appendingPathComponent("\(cacheName).json")
            )
        }
        let parser = PiLogParser(sessionsRoot: live, cacheName: cacheName)
        // An empty key set must yield nothing: unresolved pi usage is dropped,
        // never parked on a plausible account.
        checkEqual(await parser.sessions(for: []).count, 0, "no resolved keys means no sessions")
        for label in ["anthropic", "anthropic-2", "anthropic-3"] {
            let sessions = await parser.sessions(for: [label])
            let totals = sessions.flatMap(\.entries).reduce(into: (0 as Int64, 0 as Int64, 0 as Int64, 0 as Int64)) {
                $0.0 += $1.input; $0.1 += $1.output; $0.2 += $1.cacheRead; $0.3 += $1.cacheWrite5m + $1.cacheWrite1h
            }
            print("live \(label): \(sessions.count) sessions  in=\(totals.0) out=\(totals.1) cacheRead=\(totals.2) cacheWrite=\(totals.3)")
            check(sessions.allSatisfy { $0.isSubAgent == false }, "live pi sessions are all main sessions")
        }
    }
}

extension FileManager {
    /// The fixture file whose name ends in `_<id>.jsonl`.
    func enumeratedPiFile(in root: URL, named id: String) -> URL {
        let all = (enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
        return all.first { $0.lastPathComponent.hasSuffix("_\(id).jsonl") }!
    }
}

await run()

if failures.isEmpty {
    print("ALL PASS")
} else {
    for failure in failures { print("FAIL: \(failure)") }
    exit(1)
}
