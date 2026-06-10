import Foundation

/// The gemini-cli's public "installed application" OAuth client. Installed-app
/// flows cannot keep a confidential secret and Google ships these constants in
/// the open-source CLI — but Pulse deliberately does NOT vendor them: secret
/// scanners flag the literals, and Google may rotate them with a CLI release.
/// Instead they are extracted at runtime from the user's own gemini-cli
/// install (the same approach CodexBar uses).
struct GeminiOAuthClient: Sendable, Equatable {
    var clientID: String
    var clientSecret: String
}

enum GeminiOAuthClientLocator {
    /// Scans likely gemini-cli install locations and extracts the OAuth client
    /// from its bundled JavaScript. Returns nil when the CLI isn't installed —
    /// quota fetching then degrades to "open the CLI to refresh".
    static func discover(fileManager: FileManager = .default) -> GeminiOAuthClient? {
        for root in candidatePackageRoots(fileManager: fileManager) {
            if let client = extract(fromPackageAt: root, fileManager: fileManager) {
                return client
            }
        }
        return nil
    }

    /// Possible @google/gemini-cli package directories: global npm roots for
    /// Homebrew (both architectures), the default prefix, common user-level
    /// prefixes, every nvm-managed node version, and the resolved target of a
    /// `gemini` launcher symlink on the usual bin paths.
    static func candidatePackageRoots(fileManager: FileManager = .default) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let packageSuffix = "lib/node_modules/@google/gemini-cli"

        var roots: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/\(packageSuffix)"),
            URL(fileURLWithPath: "/usr/local/\(packageSuffix)"),
            home.appendingPathComponent(".npm-global/\(packageSuffix)"),
            home.appendingPathComponent("n/\(packageSuffix)"),
        ]

        let nvmVersions = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmVersions, includingPropertiesForKeys: nil
        ) {
            roots.append(contentsOf: versions.map { $0.appendingPathComponent(packageSuffix) })
        }

        // A `gemini` launcher resolves into <package>/dist/…: walk up to the
        // package directory.
        for binPath in ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini",
                        home.appendingPathComponent(".local/bin/gemini").path] {
            let resolved = URL(fileURLWithPath: binPath).resolvingSymlinksInPath()
            var directory = resolved.deletingLastPathComponent()
            for _ in 0..<5 {
                if directory.lastPathComponent == "gemini-cli" {
                    roots.append(directory)
                    break
                }
                directory.deleteLastPathComponent()
            }
        }

        return roots.filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Scans the package's JavaScript bundles for the OAuth client constants.
    static func extract(fromPackageAt root: URL, fileManager: FileManager = .default) -> GeminiOAuthClient? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var scanned = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "js" else { continue }
            guard scanned < 400 else { break } // safety cap for pathological trees
            scanned += 1
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 32_000_000 else { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            if let client = extract(fromSource: String(decoding: data, as: UTF8.self)) {
                return client
            }
        }
        return nil
    }

    /// Pure extraction (tested): both constants must appear in the same source.
    /// The patterns are shape-based so a CLI release rotating the values keeps
    /// working.
    static func extract(fromSource source: String) -> GeminiOAuthClient? {
        guard let id = firstMatch(#"[0-9]{6,}-[a-z0-9_-]{8,}\.apps\.googleusercontent\.com"#, in: source),
              let secret = firstMatch(#"GOCSPX-[A-Za-z0-9_-]{8,}"#, in: source)
        else { return nil }
        return GeminiOAuthClient(clientID: id, clientSecret: secret)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}
