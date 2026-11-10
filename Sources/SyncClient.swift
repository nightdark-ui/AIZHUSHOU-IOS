import Foundation

/// 和电脑版双向同步：补货确认 + 单款提醒线
struct SyncClient {

    struct Payload {
        var acks: [[String: Any]]
        var thresholds: [[String: Any]]
    }

    static func normalize(_ base: String) -> String? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("/") { s.removeLast() }
        if !s.lowercased().hasPrefix("http") {
            s = "https://" + s
        }
        return s
    }

    static func pull(base: String, key: String) async throws -> Payload {
        guard let root = normalize(base) else {
            throw WPSError.badPayload("没填电脑地址")
        }
        guard let url = URL(string: root + "/inv/api/sync/pull") else {
            throw WPSError.badPayload("电脑地址格式不对")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(key, forHTTPHeaderField: "X-Sync-Key")

        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        return try decode(data)
    }

    static func push(base: String, key: String,
                     acks: [[String: Any]],
                     thresholds: [[String: Any]]) async throws -> Payload {
        guard let root = normalize(base) else {
            throw WPSError.badPayload("没填电脑地址")
        }
        guard let url = URL(string: root + "/inv/api/sync/push") else {
            throw WPSError.badPayload("电脑地址格式不对")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Sync-Key")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "acks": acks, "thresholds": thresholds
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        return try decode(data)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 403 {
            throw WPSError.badPayload("同步密钥不对，检查电脑端 config.json 里的 sync.key")
        }
        if http.statusCode != 200 {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw WPSError.http(http.statusCode, body)
        }
    }

    private static func decode(_ data: Data) throws -> Payload {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WPSError.badPayload("电脑返回的不是 JSON")
        }
        if let err = root["error"] as? String, !err.isEmpty {
            throw WPSError.badPayload(err)
        }
        let acks = root["acks"] as? [[String: Any]] ?? []
        let thresholds = root["thresholds"] as? [[String: Any]] ?? []
        return Payload(acks: acks, thresholds: thresholds)
    }
}
