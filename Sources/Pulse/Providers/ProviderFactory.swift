import Foundation

/// Composition point for all provider engines, in canonical display order.
enum ProviderFactory {
    /// - Parameter captureTitles: whether the Claude log parser may read
    ///   `ai-title` records (off = strictly content-blind). Set from
    ///   `SettingsStore.useSessionTitles` at launch.
    static func makeAll(captureTitles: Bool = true) -> [any UsageProvider] {
        // Claude accounts are discovered from ~/.claude* at launch, so the
        // registry has to learn about them before anything reads allCases
        // (tab order, settings, menu bar).
        let accounts = ClaudeAccount.discover()
        ProviderRegistry.shared.register(claudeAccounts: accounts.map(\.id))

        return accounts.map { ClaudeProvider(account: $0, captureTitles: captureTitles) }
            + [
                CodexProvider(),
                CursorProvider(),
                CopilotProvider(),
                GeminiProvider(),
            ]
    }
}
