import Foundation

/// Reads generic passwords via `/usr/bin/security` rather than SecItem.
///
/// Rationale: Pulse is ad-hoc signed, so its code signature changes on every
/// rebuild. A direct SecItem read of another app's item (Claude Code's OAuth
/// credentials) would re-trigger the keychain approval dialog after each build.
/// The `security` binary is Apple-signed and stable, so the user's one-time
/// "Always Allow" sticks permanently.
///
/// SECURITY TRADEOFF (documented in README): answering "Always Allow" adds
/// /usr/bin/security itself to the item's ACL, which means any local process
/// could afterwards read the item the same way without a prompt. Users who
/// prefer the stricter posture should click "Allow" (per-session) instead, or
/// sign Pulse with a stable identity and switch this to SecItemCopyMatching.
struct KeychainReader: Sendable {
    enum Failure: Error, Equatable {
        case itemNotFound
        case accessDeniedOrTimeout
        case failed(status: Int32)
    }

    /// Guarantees a continuation is resumed exactly once across the racing
    /// termination handler and timeout watchdog.
    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }
    }

    /// Reads the password for a generic-password item. The generous default
    /// timeout leaves room for the user to answer the one-time approval dialog.
    func readGenericPassword(service: String, timeout: TimeInterval = 90) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let box = OnceBox()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", service, "-w"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            process.terminationHandler = { finished in
                let data = (finished.standardOutput as? Pipe)?
                    .fileHandleForReading.readDataToEndOfFile() ?? Data()
                guard box.claim() else { return }
                switch finished.terminationStatus {
                case 0:
                    let value = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .newlines)
                    continuation.resume(returning: value)
                case 44: // errSecItemNotFound
                    continuation.resume(throwing: Failure.itemNotFound)
                default:
                    continuation.resume(throwing: Failure.failed(status: finished.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                if box.claim() { continuation.resume(throwing: error) }
                return
            }

            let watched = process
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard watched.isRunning else { return }
                watched.terminate()
                if box.claim() {
                    continuation.resume(throwing: Failure.accessDeniedOrTimeout)
                }
            }
        }
    }
}
