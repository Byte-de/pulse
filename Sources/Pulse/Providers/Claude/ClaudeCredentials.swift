import Foundation

/// Claude Code OAuth credentials. On macOS they live in the Keychain item
/// "Claude Code-credentials" (no file); on Linux-style setups in
/// `~/.claude/.credentials.json`. Both carry the same JSON.
///
/// Read-only contract: Pulse never refreshes or rewrites these tokens —
/// Claude Code owns the refresh cycle. An expired token surfaces as a
/// sign-in hint, not a refresh attempt.
struct ClaudeCredentials: Sendable {
    static let keychainService = "Claude Code-credentials"

    var accessToken: String
    /// Epoch MILLISECONDS.
    var expiresAt: Double?
    var subscriptionType: String?
    var rateLimitTier: String?

    /// `expiresAt` is epoch milliseconds; expired once `now` reaches it.
    func isExpired(now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return now.timeIntervalSince1970 * 1000 >= expiresAt
    }

    /// "max" + "…_5x" → "Max 5×"; "pro" → "Pro".
    var planLabel: String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        let base = subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst()
        guard subscriptionType.lowercased() == "max", let tier = rateLimitTier?.lowercased() else { return base }
        if tier.contains("20x") { return "Max 20×" }
        if tier.contains("5x") { return "Max 5×" }
        return base
    }

    static func parse(json: Data) throws -> ClaudeCredentials {
        struct File: Decodable {
            struct OAuth: Decodable {
                var accessToken: String?
                var expiresAt: Double?
                var subscriptionType: String?
                var rateLimitTier: String?
            }
            var claudeAiOauth: OAuth?
        }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: json)
        } catch {
            throw ProviderFetchError.parsing(description: "Claude credentials have an unrecognized format")
        }
        guard let token = file.claudeAiOauth?.accessToken, !token.isEmpty else {
            throw ProviderFetchError.notLoggedIn(hint: "Sign in to Claude Code to start tracking.")
        }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: file.claudeAiOauth?.expiresAt,
            subscriptionType: file.claudeAiOauth?.subscriptionType,
            rateLimitTier: file.claudeAiOauth?.rateLimitTier
        )
    }
}

/// Loads credentials (file first — promptless — then Keychain) and caches them
/// briefly so a 60s poll doesn't spawn a `security` subprocess every tick.
actor ClaudeCredentialsStore {
    private let fileURL: URL
    private let keychain: KeychainReader
    private var cached: (credentials: ClaudeCredentials, loadedAt: Date)?
    /// Negative cache: a denied/timed-out keychain read must not re-prompt on
    /// every 60s tick (each `-w` read can spawn a fresh ACL dialog).
    private var lastFailure: (error: ProviderFetchError, at: Date)?

    init(
        fileURL: URL = AppPaths.home.appendingPathComponent(".claude/.credentials.json"),
        keychain: KeychainReader = KeychainReader()
    ) {
        self.fileURL = fileURL
        self.keychain = keychain
    }

    private static let cacheTTL: TimeInterval = 300

    func credentials(forceReload: Bool = false) async throws -> ClaudeCredentials {
        if !forceReload, let cached, Date.now.timeIntervalSince(cached.loadedAt) < Self.cacheTTL {
            return cached.credentials
        }
        if !forceReload, let lastFailure, Date.now.timeIntervalSince(lastFailure.at) < Self.cacheTTL {
            throw lastFailure.error
        }
        do {
            let credentials = try await load()
            cached = (credentials, .now)
            lastFailure = nil
            return credentials
        } catch let error as ProviderFetchError {
            lastFailure = (error, .now)
            throw error
        }
    }

    /// Whether a recent successful load proves the credential source exists,
    /// letting the connection probe skip its `security` subprocess.
    var hasFreshCache: Bool {
        guard let cached else { return false }
        return Date.now.timeIntervalSince(cached.loadedAt) < Self.cacheTTL
    }

    func invalidate() {
        cached = nil
        lastFailure = nil
    }

    private func load() async throws -> ClaudeCredentials {
        if let data = try? Data(contentsOf: fileURL) {
            return try ClaudeCredentials.parse(json: data)
        }
        do {
            let secret = try await keychain.readGenericPassword(service: ClaudeCredentials.keychainService)
            return try ClaudeCredentials.parse(json: Data(secret.utf8))
        } catch KeychainReader.Failure.itemNotFound {
            throw ProviderFetchError.notLoggedIn(hint: "Sign in to Claude Code to start tracking.")
        } catch KeychainReader.Failure.accessDeniedOrTimeout {
            throw ProviderFetchError.notLoggedIn(
                hint: "Approve Keychain access for Pulse to read Claude Code's credentials."
            )
        } catch let error as ProviderFetchError {
            throw error
        } catch {
            throw ProviderFetchError.notLoggedIn(hint: "Claude Code credentials unavailable.")
        }
    }

    // MARK: - Promptless existence probe

    /// True when either credential source exists. The Keychain check omits `-w`
    /// (metadata only), so it never reads the secret and never triggers the
    /// ACL approval dialog — safe to run every refresh tick.
    func sourceExists() async -> Bool {
        if hasFreshCache { return true }
        if FileManager.default.fileExists(atPath: fileURL.path) { return true }
        return await Self.keychainItemExists(service: ClaudeCredentials.keychainService)
    }

    /// Runs `security find-generic-password -s <service>` (NO `-w`).
    /// Exit status 0 ⇔ the item exists. Never blocks the cooperative pool;
    /// a watchdog terminates the subprocess if it somehow stalls.
    static func keychainItemExists(service: String, timeout: TimeInterval = 10) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumed = OnceFlag()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", service]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            process.terminationHandler = { finished in
                // Drain so the child can never block on a full pipe buffer.
                _ = (finished.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
                _ = (finished.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
                guard resumed.claim() else { return }
                continuation.resume(returning: finished.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                if resumed.claim() { continuation.resume(returning: false) }
                return
            }

            let watched = process
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard watched.isRunning else { return }
                watched.terminate()
                if resumed.claim() { continuation.resume(returning: false) }
            }
        }
    }

    /// Guarantees the continuation resumes exactly once across the racing
    /// termination handler and timeout watchdog.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
