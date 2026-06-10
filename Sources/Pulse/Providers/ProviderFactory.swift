import Foundation

/// Composition point for all provider engines, in canonical display order.
enum ProviderFactory {
    static func makeAll() -> [any UsageProvider] {
        [
            ClaudeProvider(),
            CodexProvider(),
            CursorProvider(),
            CopilotProvider(),
            GeminiProvider(),
        ]
    }
}
