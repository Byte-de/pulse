import SwiftUI

/// Not-connected state for a provider tab: one glyph, one sentence, one hint.
/// Appears with a single opacity fade — no illustration parade, no bounce.
struct NotConnectedView: View {
    let descriptor: ProviderDescriptor
    let hint: String
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ThemedIcon(symbol: "key.slash", pointSize: 28, weight: .light)
                .foregroundStyle(PulseColor.accent(descriptor.id).opacity(0.6))
            Text("\(descriptor.name) isn't connected.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Text(hint)
                .font(Typo.footer)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            BarButton(title: "Open Settings", action: openSettings)
                .padding(.top, 2)
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }
}

/// Hard error state (no cached data to show).
struct ProviderErrorView: View {
    let descriptor: ProviderDescriptor
    let error: ProviderFetchError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ThemedIcon(symbol: "exclamationmark.triangle", pointSize: 26, weight: .light)
                .foregroundStyle(PulseColor.warnStrong)
            Text(error.userMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            BarButton(title: "Try Again", action: retry)
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }
}

/// First-load placeholder while a provider fetches.
struct ProviderLoadingView: View {
    let descriptor: ProviderDescriptor

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Reading \(descriptor.name) usage…")
                .font(Typo.footer)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }
}
