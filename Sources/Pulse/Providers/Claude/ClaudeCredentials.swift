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

/// Loads credentials (file first — promptless — then Keychain).
///
/// Caching policy: **the token itself is never cached across a refresh**. The
/// file read is a plain `Data(contentsOf:)`, so re-reading it every tick costs
/// nothing and always sees the token Claude Code just rotated. Only a
/// Keychain-sourced token is held briefly, because each `-w` read spawns a
/// `security` subprocess that can raise an ACL dialog — and even that copy is
/// dropped the moment `expiresAt` passes, so Pulse never sends a token it can
/// already tell is dead.
actor ClaudeCredentialsStore {
    private let fileURL: URL
    /// Keychain service for this account. Defaults to the primary profile's.
    private let keychainService: String
    private let keychain: KeychainReader
    /// Keychain-sourced credentials only; a file-sourced token is re-read
    /// every time.
    private var cached: (credentials: ClaudeCredentials, loadedAt: Date)?
    /// Negative cache: a denied/timed-out keychain read must not re-prompt on
    /// every 60s tick (each `-w` read can spawn a fresh ACL dialog).
    private var lastFailure: (error: ProviderFetchError, at: Date)?

    init(
        fileURL: URL = AppPaths.home.appendingPathComponent(".claude/.credentials.json"),
        keychainService: String = ClaudeCredentials.keychainService,
        keychain: KeychainReader = KeychainReader()
    ) {
        self.fileURL = fileURL
        self.keychainService = keychainService
        self.keychain = keychain
    }

    private static let cacheTTL: TimeInterval = 300

    func credentials(forceReload: Bool = false) async throws -> ClaudeCredentials {
        if !forceReload, let cached,
           Date.now.timeIntervalSince(cached.loadedAt) < Self.cacheTTL,
           !cached.credentials.isExpired() {
            return cached.credentials
        }
        if !forceReload, let lastFailure, Date.now.timeIntervalSince(lastFailure.at) < Self.cacheTTL {
            throw lastFailure.error
        }
        do {
            let loaded = try await load()
            // File-sourced tokens are cheap to re-read, so nothing is retained.
            cached = loaded.fromKeychain ? (loaded.credentials, .now) : nil
            lastFailure = nil
            return loaded.credentials
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

    private func load() async throws -> (credentials: ClaudeCredentials, fromKeychain: Bool) {
        // The file is only authoritative while its token is still valid. A
        // stale `~/.claude/.credentials.json` left behind by an older install
        // outlives the token inside it, and preferring it unconditionally
        // makes Pulse send a long-dead token forever while the live one sits
        // in the Keychain — 401 on every poll, then a 429 that hides the
        // cause. An expired file therefore falls through.
        let fileCredentials = (try? Data(contentsOf: fileURL)).flatMap {
            try? ClaudeCredentials.parse(json: $0)
        }
        if let fileCredentials, !fileCredentials.isExpired() {
            return (fileCredentials, false)
        }
        do {
            let secret = try await keychain.readGenericPassword(service: keychainService)
            return (try ClaudeCredentials.parse(json: Data(secret.utf8)), true)
        } catch KeychainReader.Failure.itemNotFound {
            // No Keychain item: an expired file is still the best evidence of
            // who is signed in, and the endpoint's 401 is the honest answer.
            if let fileCredentials { return (fileCredentials, false) }
            throw ProviderFetchError.notLoggedIn(hint: "Sign in to Claude Code to start tracking.")
        } catch KeychainReader.Failure.accessDeniedOrTimeout {
            if let fileCredentials { return (fileCredentials, false) }
            throw ProviderFetchError.notLoggedIn(
                hint: "Approve Keychain access for Pulse to read Claude Code's credentials."
            )
        } catch let error as ProviderFetchError {
            if let fileCredentials { return (fileCredentials, false) }
            throw error
        } catch {
            if let fileCredentials { return (fileCredentials, false) }
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
        return await Self.keychainItemExists(service: keychainService)
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
