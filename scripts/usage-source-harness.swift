// End-to-end assertions for the "Count Tokens From" switches, compiled against
// the real ClaudeProvider by scripts/verify-usage-sources.sh.
//
// This is the check a unit test cannot make: the switch lives in Settings, the
// gate lives in Core, and the *reader* is an actor several layers away. Each
// side can look right on its own while the wire between them is cut, and the
// symptom (a toggle that does nothing) is silent.
//
// It runs read-only over the live log trees on this machine and asserts
// relationships, never machine-specific totals: with a source off, that
// source's sessions must be gone and every other source's must be untouched.
// Prints "ALL PASS" only when every check holds.

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

/// Session-id origin, so a breakdown row can be attributed back to the writer
/// that produced it. jcode ids carry their own prefix; pi ids are the uuid in
/// its file name; anything else came from Claude Code's own logs.
enum Writer: String {
    case claude, jcode, pi
}

func writer(ofSessionID id: String) -> Writer {
    // A session that billed two accounts is suffixed "#claude-2".
    let base = id.components(separatedBy: "#").first ?? id
    if base.hasPrefix("session_") { return .jcode }
    return piSessionIDs.contains(base) ? .pi : .claude
}

let piSessionIDs: Set<String> = {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/sessions")
    let urls = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "jsonl" }
    return Set(urls.compactMap { $0.deletingPathExtension().lastPathComponent.components(separatedBy: "_").last })
}()

/// pi session ids this provider claims, for the double-count check.
@MainActor
func piSessionIDs(provider: ClaudeProvider) async -> Set<String> {
    UsageSourceGate.shared.current = .all
    guard let breakdown = await provider.projectBreakdown(timeframe: .last30Days) else { return [] }
    var ids: Set<String> = []
    for project in breakdown.projects {
        for session in project.sessions where writer(ofSessionID: session.id) == .pi {
            ids.insert(session.id.components(separatedBy: "#").first ?? session.id)
        }
    }
    return ids
}

/// Sessions per writer for one selection of sources.
@MainActor
func counts(_ selection: UsageSourceSelection, provider: ClaudeProvider) async -> [Writer: Int] {
    // Deliberately NOT passing `sources:` here: the default is the gate, so
    // this path exercises the Settings wiring (SettingsStore -> gate -> actor).
    // The window's explicit filter is checked separately below.
    UsageSourceGate.shared.current = selection
    guard let breakdown = await provider.projectBreakdown(timeframe: .last30Days) else { return [:] }
    var tally: [Writer: Int] = [:]
    for project in breakdown.projects {
        for session in project.sessions {
            tally[writer(ofSessionID: session.id), default: 0] += 1
        }
    }
    return tally
}

@MainActor
func run() async {
    // Every account, not just the primary. Which account a harness bills is a
    // fact about the machine, not about which tab is first: on this one every
    // pi session belongs to the *secondary* account, so a harness that only
    // looked at `~/.claude` would skip the pi checks and still report a clean
    // pass. The invariants are asserted per account, and the run fails if no
    // account exercised a given writer at all.
    var exercised: Set<Writer> = []
    var checkedAccounts = 0
    // pi session ids seen per account: one session bills one account, so two
    // accounts claiming the same session means the totals are double counted.
    var piSessionsByAccount: [String: Set<String>] = [:]

    for account in ClaudeAccount.discover() {
        let provider = ClaudeProvider(account: account)
        let all = await counts(.all, provider: provider)
        piSessionsByAccount[account.id.rawValue] = await piSessionIDs(provider: provider)
        guard !all.isEmpty else { continue }
        checkedAccounts += 1
        let label = "\(account.id.rawValue) [\(account.email ?? "?")]"
        // jcode renames its account labels while its session writer keeps
        // stamping the original `claude-N`, so an account has to answer to
        // both. Matching only the current label zeroed the Claude tab on
        // 2026-09-01 with no error anywhere.
        if (all[.jcode] ?? 0) > 0 {
            check(
                account.jcodeAccountLabels.contains { $0.hasPrefix("claude-") && Int($0.dropFirst("claude-".count)) != nil },
                "\(label): keeps the legacy claude-N label jcode still writes"
            )
        }
        print("\(label): claude=\(all[.claude] ?? 0) jcode=\(all[.jcode] ?? 0) pi=\(all[.pi] ?? 0) sessions")

        for writer in [Writer.claude, .jcode, .pi] where (all[writer] ?? 0) > 0 {
            exercised.insert(writer)
            var selection = UsageSourceSelection.all
            switch writer {
            case .claude: selection.providerLogs = false
            case .jcode: selection.jcode = false
            case .pi: selection.pi = false
            }
            let without = await counts(selection, provider: provider)
            check(without[writer] == nil, "\(label): \(writer.rawValue) off removes every \(writer.rawValue) session")
            for other in [Writer.claude, .jcode, .pi] where other != writer {
                check(
                    without[other] == all[other],
                    "\(label): \(writer.rawValue) off leaves \(other.rawValue) untouched"
                )
            }
        }

        let none = await counts(.none, provider: provider)
        check(none.isEmpty, "\(label): every source off leaves no attributable usage")

        UsageSourceGate.shared.current = .all
        let restored = await counts(.all, provider: provider)
        check(restored == all, "\(label): turning the sources back on restores the original set")
    }

    for (lhs, lhsSessions) in piSessionsByAccount {
        for (rhs, rhsSessions) in piSessionsByAccount where lhs < rhs {
            let shared = lhsSessions.intersection(rhsSessions)
            check(shared.isEmpty, "no pi session is claimed by both \(lhs) and \(rhs) (\(shared.count) shared)")
        }
    }

    check(checkedAccounts > 0, "at least one Claude account has attributable usage")
    for writer in [Writer.claude, .jcode, .pi] {
        // Loud rather than silent: a machine with no pi usage cannot verify the
        // pi switch, and must say so instead of passing.
        if !exercised.contains(writer) { print("SKIPPED: no \(writer.rawValue) sessions on any account") }
    }
    // Absolute, not relative. The per-account checks above only compare a
    // filtered run against an unfiltered one, so they stay green when a whole
    // writer's usage *disappears* - which is precisely the bug jcode's account
    // rename caused. Each writer must actually show up somewhere.
    check(exercised.contains(.pi), "some account has pi usage to test the pi switch with")
    check(exercised.contains(.jcode), "some account still sees jcode sessions")
    check(exercised.contains(.claude), "some account still sees Claude Code's own sessions")

    // The breakdown window's filter must be independent of the panel's
    // switches: it asks a different question and has to answer it without
    // changing what the menu bar reports. Gate off, argument on -> everything
    // still comes back.
    let primary = ClaudeProvider(account: ClaudeAccount.discover().first { $0.id == .claude }!)
    UsageSourceGate.shared.current = .none
    let gateOffArgumentOn = await primary.projectBreakdown(timeframe: .last30Days, sources: .all)
    check((gateOffArgumentOn?.projects.count ?? 0) > 0, "breakdown honours its argument, not the panel's gate")
    UsageSourceGate.shared.current = .all
    let gateOnArgumentOff = await primary.projectBreakdown(timeframe: .last30Days, sources: .none)
    check(gateOnArgumentOff == nil, "breakdown with no sources returns nothing even with the gate wide open")

    // Persistence round-trip: the filter survives a window close only if it
    // encodes and decodes, and an absent key must mean ALL, never none.
    let subset = UsageSourceSelection(providerLogs: false, jcode: true, pi: false)
    check(UsageSourceSelection(stored: subset.storedValue) == subset, "source filter round-trips through storage")
    check(UsageSourceSelection(stored: nil) == .all, "an unset filter means every source")
    check(UsageSourceSelection(stored: []) == .none, "an explicitly empty filter means none")
    check(subset.summary == "jcode", "filter summary names the enabled sources")

    // Label-set construction, against a FABRICATED auth file rather than the
    // live one. jcode rewrites `~/.jcode/auth.json`: labels went claude-1 ->
    // claude-otter -> claude-1 within one hour on 2026-09-01, while its session
    // writer never stopped stamping claude-1. So "does this work" cannot be
    // asked of whatever the file happens to say this minute - when the current
    // label and the legacy one coincide, a broken implementation looks fine.
    let renamed = [
        ClaudeAccount.JcodeAccountRef(label: "claude-otter", email: "first@example.com", index: 0),
        ClaudeAccount.JcodeAccountRef(label: "claude-fox", email: "second@example.com", index: 1),
    ]
    checkEqual(
        ClaudeAccount.labels(in: renamed, forEmail: "first@example.com", isPrimary: true),
        ["claude-otter", "claude-1"],
        "a renamed account still answers to the claude-N its sessions carry"
    )
    checkEqual(
        ClaudeAccount.labels(in: renamed, forEmail: "SECOND@example.com", isPrimary: false),
        ["claude-fox", "claude-2"],
        "the match is by email, case-insensitively, and keeps the ordinal label"
    )
    checkEqual(
        ClaudeAccount.labels(in: renamed, forEmail: "nobody@example.com", isPrimary: false),
        [],
        "an account jcode has never seen claims no jcode sessions"
    )

    // pi attribution is by account identity, never by the order of keys in
    // pi's auth file. Guessing ordinally put 153.4M tokens on the wrong tab.
    let resolved = await PiAccountResolver().resolveAll()
    if resolved.isEmpty {
        print("SKIPPED: no pi key could be resolved (offline or signed out)")
    } else {
        for (key, entry) in resolved.sorted(by: { $0.key < $1.key }) {
            print("pi '\(key)' -> \(entry.email ?? "?")")
        }
        let accountsByUUID = Dictionary(
            grouping: ClaudeAccount.discover().compactMap { account in account.accountUUID.map { ($0, account) } },
            by: { $0.0 }
        )
        for (key, entry) in resolved {
            check(
                accountsByUUID[entry.accountUUID] != nil || entry.email == nil,
                "resolved pi key '\(key)' maps to a Claude account Pulse knows"
            )
        }
    }

    // Codex keeps its own logs and no harness writes to them, so "provider
    // sessions" is the only switch that touches it - and it must touch it, or
    // the switch is a Claude-only switch wearing a general label.
    let codex = CodexProvider()
    UsageSourceGate.shared.current = .all
    let codexOn = await codex.projectBreakdown(timeframe: .last30Days, sources: .all)
    let codexOff = await codex.projectBreakdown(
        timeframe: .last30Days,
        sources: UsageSourceSelection(providerLogs: false, jcode: true, pi: true)
    )
    if codexOn == nil {
        print("SKIPPED: no Codex sessions on this machine")
    } else {
        check(codexOff == nil, "provider logs off empties the Codex breakdown too")
    }

    UsageSourceGate.shared.current = .all
}

await run()

if failures.isEmpty {
    print("ALL PASS")
} else {
    for failure in failures { print("FAIL: \(failure)") }
    exit(1)
}
