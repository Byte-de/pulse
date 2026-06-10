import Foundation

// MARK: - Transport

/// Minimal POST transport for the Gemini engine, injectable so tests never
/// touch the network. Core's `HTTPClient` folds non-2xx statuses into thrown
/// errors and discards the response body; the Gemini flows need both intact
/// to map Google-specific failures (400 `invalid_grant` → signed out,
/// 403/404 on the quota RPCs → quota API unavailable).
protocol GeminiTransport: Sendable {
    /// Throws `ProviderFetchError.network` for transport-level failures only;
    /// HTTP error statuses are returned, not thrown.
    func post(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

/// Live implementation. Session configuration mirrors Core's `HTTPClient`:
/// ephemeral, cookies and caching disabled.
struct GeminiURLSessionTransport: GeminiTransport {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ProviderFetchError.network(description: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.network(description: "Non-HTTP response")
        }
        return (http.statusCode, data)
    }
}

// MARK: - Quota API

/// Google Code Assist private API — the same RPCs gemini-cli calls (schemas
/// extracted from its source; docs/RESEARCH/gemini.md §4). All calls are POST
/// with `Authorization: Bearer` + JSON bodies; the method name follows a colon
/// (".../v1internal:loadCodeAssist", not a path segment).
struct GeminiQuotaAPI: Sendable {
    static let loadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let retrieveUserQuotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!

    private let transport: any GeminiTransport

    init(transport: any GeminiTransport) {
        self.transport = transport
    }

    // MARK: Response shapes

    /// Tier + project discovery (`v1internal:loadCodeAssist`).
    struct LoadCodeAssist: Sendable, Equatable {
        /// `currentTier.id`: "free-tier" | "standard-tier" | "legacy-tier" | …
        var tierID: String?
        /// `cloudaicompanionProject` — required for the quota RPC.
        var project: String?
    }

    /// One entry of `retrieveUserQuota.buckets` (one per model × token type).
    struct QuotaBucket: Sendable, Equatable {
        /// int64-as-string, e.g. "950".
        var remainingAmount: String?
        /// Fraction REMAINING, 0…1 (not used).
        var remainingFraction: Double?
        /// RFC3339 timestamp — the authoritative reset clock per bucket.
        var resetTime: String?
        var tokenType: String?
        var modelId: String?

        init(
            remainingAmount: String? = nil,
            remainingFraction: Double? = nil,
            resetTime: String? = nil,
            tokenType: String? = nil,
            modelId: String? = nil
        ) {
            self.remainingAmount = remainingAmount
            self.remainingFraction = remainingFraction
            self.resetTime = resetTime
            self.tokenType = tokenType
            self.modelId = modelId
        }
    }

    // MARK: RPCs

    func loadCodeAssist(token: String) async throws -> LoadCodeAssist {
        // Minimal body, CodexBar-verified (GeminiStatusProbe.swift:387).
        let body = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)
        let data = try await post(Self.loadCodeAssistURL, body: body, token: token)
        return Self.parseLoadCodeAssist(data)
    }

    func retrieveUserQuota(token: String, project: String) async throws -> [QuotaBucket] {
        let body = (try? JSONEncoder().encode(["project": project])) ?? Data("{}".utf8)
        let data = try await post(Self.retrieveUserQuotaURL, body: body, token: token)
        return Self.parseQuotaBuckets(data)
    }

    private func post(_ url: URL, body: Data, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (status, responseBody) = try await transport.post(request)
        switch status {
        case 200...299:
            return responseBody
        case 401:
            throw ProviderFetchError.unauthorized
        case 403, 404:
            // Google is sunsetting individual Code Assist tiers (June 2026);
            // affected accounts get 403/404 here. Surface a truthful message
            // instead of a generic auth/HTTP error.
            throw ProviderFetchError.dataUnavailable(description: "Gemini quota API unavailable for this account")
        default:
            throw ProviderFetchError.http(status: status)
        }
    }

    // MARK: Tolerant parsing (pure, tested)

    /// Field-by-field tolerant parse: a missing/odd field never sinks the
    /// response. `cloudaicompanionProject` may be a string (CLI usage) or an
    /// `{id|projectId, name}` object in some variants — both are handled.
    static func parseLoadCodeAssist(_ data: Data) -> LoadCodeAssist {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return LoadCodeAssist(tierID: nil, project: nil)
        }
        let tierID = (root["currentTier"] as? [String: Any])?["id"] as? String
        var project = root["cloudaicompanionProject"] as? String
        if project == nil, let object = root["cloudaicompanionProject"] as? [String: Any] {
            project = (object["id"] as? String) ?? (object["projectId"] as? String)
        }
        return LoadCodeAssist(
            tierID: (tierID?.isEmpty == false) ? tierID : nil,
            project: (project?.isEmpty == false) ? project : nil
        )
    }

    /// Lossy bucket decode: malformed entries are dropped, valid siblings kept.
    static func parseQuotaBuckets(_ data: Data) -> [QuotaBucket] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawBuckets = root["buckets"] as? [Any]
        else { return [] }

        return rawBuckets.compactMap { element in
            guard let dict = element as? [String: Any] else { return nil }
            let fraction = (dict["remainingFraction"] as? Double)
                ?? (dict["remainingFraction"] as? String).flatMap(Double.init)
            let amount = (dict["remainingAmount"] as? String)
                ?? (dict["remainingAmount"] as? Int).map(String.init)
            return QuotaBucket(
                remainingAmount: amount,
                remainingFraction: fraction,
                resetTime: dict["resetTime"] as? String,
                tokenType: dict["tokenType"] as? String,
                modelId: dict["modelId"] as? String
            )
        }
    }

    // MARK: Derivation (pure, tested)

    /// CodexBar-verified rule: group buckets by model, keep the LOWEST
    /// remaining fraction per model (the worst lane, usually input tokens);
    /// utilization = (1 − fraction) × 100. Buckets without a model id or
    /// fraction are skipped. Returns one window per model, worst first.
    static func quotaWindows(from buckets: [QuotaBucket]) -> [LimitWindow] {
        var worstPerModel: [String: (fraction: Double, resetTime: String?)] = [:]
        for bucket in buckets {
            guard let model = bucket.modelId, !model.isEmpty,
                  let fraction = bucket.remainingFraction
            else { continue }
            if let existing = worstPerModel[model], existing.fraction <= fraction { continue }
            worstPerModel[model] = (fraction, bucket.resetTime)
        }

        return worstPerModel
            .map { model, info in
                LimitWindow(
                    id: "quota.\(model)",
                    title: ModelNames.display(model),
                    systemImage: "sparkle",
                    utilization: max(0, min(1, 1 - info.fraction)) * 100,
                    resetsAt: info.resetTime.flatMap(Self.parseISO),
                    windowDuration: 24 * 3600
                )
            }
            .sorted {
                if $0.utilization != $1.utilization { return $0.utilization > $1.utilization }
                return $0.id < $1.id // deterministic order for ties
            }
    }

    /// Tier id → plan label; a Workspace account (id_token `hd` claim) gets
    /// " (Workspace)" appended.
    static func tierLabel(id: String?, isWorkspace: Bool) -> String? {
        let base: String? = switch id {
        case "free-tier": "Free"
        case "standard-tier": "Paid"
        case "legacy-tier": "Legacy"
        case .some(let other): other.replacingOccurrences(of: "-", with: " ").capitalized
        case nil: nil
        }
        guard let base else { return isWorkspace ? "Workspace" : nil }
        return isWorkspace ? "\(base) (Workspace)" : base
    }

    /// RFC3339/ISO-8601 with or without fractional seconds.
    static func parseISO(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(string, strategy: .iso8601) { return date }
        // Offset spellings the strict strategies reject (e.g. "+00:00").
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
