import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var settings: SettingsStore { environment.settings }
    private var store: UsageStore { environment.store }

    /// Shipped version from the bundle's Info.plist — the single source of
    /// truth (set by build-app.sh), so the About row never drifts from the build.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        settings.launchAtLogin = newValue
                        launchAtLogin = settings.launchAtLogin
                    }

                Picker("Refresh every", selection: $settings.refreshInterval) {
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("2 minutes").tag(TimeInterval(120))
                    Text("5 minutes").tag(TimeInterval(300))
                }

                Picker("Limit gauges show", selection: $settings.gaugeDirection) {
                    ForEach(SettingsStore.GaugeDirection.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.gaugeDirection == .used
                    ? "Bars fill left to right as you spend."
                    : "Bars drain right to left like a fuel gauge.")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)

                Toggle(isOn: $settings.showPaceMarker) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show pace marker")
                        Text("A tick on each gauge marking how far through the window you are, so the bar can be read against the clock: ahead of it means you are burning the limit faster than it refills.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(ProviderID.allCases) { id in
                    providerRow(id, subtitle: claudeAccountSubtitle(id))
                }
            } header: {
                Text("Providers")
            } footer: {
                if !discoveredClaudeAccounts.isEmpty {
                    Text("Extra Claude accounts are found by scanning your home folder for `.claude-*` directories, and start switched off. Create one with `CLAUDE_CONFIG_DIR=~/.claude-work claude`, then restart Pulse.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Panel") {
                Picker("Providers", selection: $settings.panelLayout) {
                    ForEach(SettingsStore.PanelLayout.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.panelLayout == .columns
                    ? "One click shows every enabled provider at once, side by side. The panel widens by one column per provider, capped at what the screen holds."
                    : "One provider at a time, switched with the tab bar (⌘1…⌘4, arrow keys).")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)

                Toggle(isOn: $settings.showSystemStats) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show this Mac's stats")
                        Text("A sidebar left of the providers with CPU, memory pressure, swap and free disk — what decides whether the machine can take another local agent, next to what decides whether the account can.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $settings.showSystemProcesses) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("List top processes")
                        Text("The four heaviest processes by CPU, read from `ps` while the panel is open.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.showSystemStats)
            }

            Section("Menu Bar") {
                Picker("Style", selection: $settings.menuBarStyle) {
                    Text("Provider stats").tag(SettingsStore.MenuBarStyle.stats)
                    Text("Icon only").tag(SettingsStore.MenuBarStyle.icon)
                }
                .pickerStyle(.segmented)

                if settings.menuBarStyle == .stats {
                    ForEach(ProviderID.allCases) { id in
                        Toggle(
                            environment.descriptor(for: id).name,
                            isOn: menuBarBinding(for: id)
                        )
                        .disabled(!settings.enabledProviders.contains(id))
                    }
                }
            }

            Section {
                sourceToggle(
                    isOn: $settings.countProviderLogs,
                    title: "Provider sessions",
                    detail: "What the provider's own CLI logged — `~/.claude/projects`, `~/.codex/sessions`."
                )
                sourceToggle(
                    isOn: $settings.countJcodeSessions,
                    title: "jcode sessions",
                    detail: "`~/.jcode/sessions`. jcode runs against these same accounts, so its tokens are billed here, not somewhere else."
                )
                sourceToggle(
                    isOn: $settings.countPiSessions,
                    title: "pi sessions",
                    detail: "`~/.pi/agent/sessions`. Same account, different harness."
                )
            } header: {
                Text("Count Tokens From")
            } footer: {
                Text("Applies to the token card, the daily chart and the breakdown together. Limits and quotas are never affected: they come from the provider's API and belong to the account, whichever tool spent it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Usage Breakdown") {
                Toggle(isOn: $settings.useSessionTitles) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show session titles")
                        Text("Uses the short titles your CLI already generates (e.g. Claude's), read only on your Mac. Off keeps the breakdown strictly content-blind.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Byte Pulse").font(.system(size: 13, weight: .semibold))
                        Text("AI usage in your menu bar — a Byte product.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(appVersion)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    /// One "count this source" switch. Every change forces an immediate
    /// refresh: the whole point of the switch is to watch the totals move, and
    /// waiting up to five minutes for the next tick reads as a broken toggle.
    private func sourceToggle(isOn: Binding<Bool>, title: String, detail: String) -> some View {
        Toggle(isOn: Binding(
            get: { isOn.wrappedValue },
            set: { newValue in
                isOn.wrappedValue = newValue
                environment.scheduler.refreshAll()
            }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(.init(detail))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func providerRow(_ id: ProviderID, subtitle: String? = nil) -> some View {
        let descriptor = environment.descriptor(for: id)
        let record = store.record(for: id)

        return HStack {
            Toggle(isOn: enabledBinding(for: id)) {
                HStack(spacing: 6) {
                    Circle().fill(PulseColor.accent(id)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(descriptor.name)
                        Text(subtitle ?? statusLine(record: record, descriptor: descriptor))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Secondary Claude accounts, i.e. everything discovered under `~/.claude-*`.
    private var discoveredClaudeAccounts: [ProviderID] {
        ProviderID.allCases.filter { $0.isClaudeAccount && $0 != .claude }
    }

    /// For a discovered account, lead with the directory it reads: with several
    /// "Claude Something" rows, the config dir is the only thing that tells
    /// them apart. nil for built-ins, which keep their normal status line.
    private func claudeAccountSubtitle(_ id: ProviderID) -> String? {
        guard id.isClaudeAccount, id != .claude else { return nil }
        let record = store.record(for: id)
        let descriptor = environment.descriptor(for: id)
        let suffix = id.rawValue.dropFirst(ProviderID.claudeAccountPrefix.count)
        return "~/.claude-\(suffix) · \(statusLine(record: record, descriptor: descriptor))"
    }

    private func statusLine(record: ProviderRecord, descriptor: ProviderDescriptor) -> String {
        switch record.displayState {
        case .data:
            let plan = record.snapshot?.plan.map { "\($0) · " } ?? ""
            let account = record.snapshot?.accountLabel ?? "Connected"
            return plan + account
        case .notConnected:
            return "Not connected — \(descriptor.setupHint)"
        case .error(let error):
            return error.userMessage
        case .loading:
            return "Checking…"
        }
    }

    private func enabledBinding(for id: ProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.enabledProviders.contains(id) },
            set: { enabled in
                if enabled {
                    settings.enabledProviders = ProviderID.allCases.filter {
                        settings.enabledProviders.contains($0) || $0 == id
                    }
                } else {
                    settings.enabledProviders.removeAll { $0 == id }
                }
                environment.scheduler.syncLoops()
            }
        )
    }

    private func menuBarBinding(for id: ProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.menuBarProviders.contains(id) },
            set: { visible in
                if visible {
                    settings.menuBarProviders.insert(id)
                } else {
                    settings.menuBarProviders.remove(id)
                }
            }
        )
    }
}
