import Foundation

/// 和电脑版双向同步：补货确认 + 单款提醒线
///
/// 电脑端是自签名证书，URL 会话要允许（只用于连你自己的电脑）。
struct SyncClient {

    struct Payload {
        var acks: [[String: Any]]
        var thresholds: [[String: Any]]
    }

    /// 接受自签名证书的会话
    private final class TrustingDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config,
                          delegate: TrustingDelegate(),
                          delegateQueue: nil)
    }()

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

        let data = try await send(req, fallbackHTTP: root)
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

        let data = try await send(req, fallbackHTTP: root)
        return try decode(data)
    }

    static func history(base: String, key: String, days: Int = 30) async throws -> [[String: Any]] {
        guard let root = normalize(base) else {
            throw WPSError.badPayload("没填电脑地址")
        }
        guard let url = URL(string: root + "/inv/api/sync/history?days=\(days)") else {
            throw WPSError.badPayload("电脑地址格式不对")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue(key, forHTTPHeaderField: "X-Sync-Key")

        let data = try await send(req, fallbackHTTP: root)
        guard let rootObj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WPSError.badPayload("电脑返回的不是 JSON")
        }
        if let err = rootObj["error"] as? String, !err.isEmpty {
            throw WPSError.badPayload(err)
        }
        return rootObj["items"] as? [[String: Any]] ?? []
    }

    /// 电脑端昨天（或最近一次）的快照，用来当补货判断的基准
    static func baseline(base: String, key: String) async throws -> (day: String, values: [String: Double])? {
        guard let root = normalize(base) else {
            throw WPSError.badPayload("没填电脑地址")
        }
        guard let url = URL(string: root + "/inv/api/sync/snapshot") else {
            throw WPSError.badPayload("电脑地址格式不对")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue(key, forHTTPHeaderField: "X-Sync-Key")

        let data = try await send(req, fallbackHTTP: root)
        guard let rootObj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WPSError.badPayload("电脑返回的不是 JSON")
        }
        if let err = rootObj["error"] as? String, !err.isEmpty {
            throw WPSError.badPayload(err)
        }
        guard let day = rootObj["date"] as? String, !day.isEmpty else { return nil }
        let raw = rootObj["values"] as? [String: Any] ?? [:]
        var values: [String: Double] = [:]
        for (k, v) in raw {
            if let n = v as? NSNumber { values[k] = n.doubleValue }
            else if let d = v as? Double { values[k] = d }
        }
        return values.isEmpty ? nil : (day, values)
    }

    /// 先按原样发；https 失败就换 http 再试一次（电脑端两种都听）
    private static func send(_ request: URLRequest, fallbackHTTP root: String) async throws -> Data {
        do {
            return try await rawSend(request)
        } catch {
            guard let url = request.url,
                  url.scheme?.lowercased() == "https",
                  root.lowercased().hasPrefix("https://") else {
                throw error
            }
            var plain = root.replacingOccurrences(of: "https://", with: "http://")
            if plain.hasSuffix("/") { plain.removeLast() }
            let path = url.absoluteString.replacingOccurrences(of: root, with: plain)
            guard let retryURL = URL(string: path) else { throw error }

            var retry = request
            retry.url = retryURL
            return try await rawSend(retry)
        }
    }

    private static func rawSend(_ request: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: request)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 403 {
                throw WPSError.badPayload("同步密钥不对，检查电脑端 config.json 里的 sync.key")
            }
            if http.statusCode != 200 {
                let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
                throw WPSError.http(http.statusCode, body)
            }
        }
        return data
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
