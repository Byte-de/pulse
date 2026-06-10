import Foundation

/// Minimal JWT payload inspection (no signature verification — we only read
/// claims from tokens the user's own CLIs stored locally).
enum JWT {
    /// Decodes the payload segment of a JWT into a JSON dictionary.
    static func payload(of token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        guard let data = decodeBase64URL(String(segments[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Reads a claim, supporting dotted paths into nested objects
    /// (e.g. `https://api.openai.com/auth.chatgpt_plan_type`is a single key,
    /// while `auth.user.id` walks nested dictionaries).
    static func claim<T>(_ key: String, of token: String, as type: T.Type = T.self) -> T? {
        guard let payload = payload(of: token) else { return nil }
        if let direct = payload[key] as? T { return direct }
        var node: Any? = payload
        for part in key.split(separator: ".") {
            node = (node as? [String: Any])?[String(part)]
        }
        return node as? T
    }

    private static func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}
