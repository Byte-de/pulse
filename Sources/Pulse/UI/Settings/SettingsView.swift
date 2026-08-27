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
                    ? "Bars fill left to right as you spend; the tick marks how much of the window has elapsed."
                    : "Bars drain right to left like a fuel gauge; the tick marks how much of the window is left.")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
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

            Section("Providers") {
                ForEach(ProviderID.allCases) { id in
                    providerRow(id)
                }
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

    private func providerRow(_ id: ProviderID) -> some View {
        let descriptor = environment.descriptor(for: id)
        let record = store.record(for: id)

        return HStack {
            Toggle(isOn: enabledBinding(for: id)) {
                HStack(spacing: 6) {
                    Circle().fill(PulseColor.accent(id)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(descriptor.name)
                        Text(statusLine(record: record, descriptor: descriptor))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
