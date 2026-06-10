import Foundation

/// Thin URLSession wrapper shared by all providers.
///
/// Uses an ephemeral session with cookies and caching disabled: providers manage
/// their own auth headers (Cursor sends an explicit Cookie header) and nothing
/// should leak into shared state on disk.
struct HTTPClient: Sendable {
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

    func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request)
    }

    func post(_ url: URL, headers: [String: String] = [:], jsonBody: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        return try await send(request)
    }

    /// Sends a request, mapping transport errors and non-2xx statuses to
    /// `ProviderFetchError` (401/403 → `.unauthorized`). Task cancellation is
    /// rethrown as `CancellationError` — never disguised as a network failure —
    /// so a Settings toggle mid-fetch can't poison provider state.
    func send(_ request: URLRequest) async throws -> Data {
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
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw ProviderFetchError.unauthorized
        default:
            throw ProviderFetchError.http(status: http.statusCode)
        }
    }

    /// Decodes JSON, mapping failures to `ProviderFetchError.parsing`.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProviderFetchError.parsing(description: "\(T.self): \(error.localizedDescription)")
        }
    }
}
