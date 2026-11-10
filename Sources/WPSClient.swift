import Foundation

enum WPSError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case badPayload(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没填 WPS 令牌 / 文件 ID / 脚本 ID"
        case let .http(code, body):
            return "WPS 返回 HTTP \(code)：\(body)"
        case let .badPayload(msg):
            return "WPS 返回异常：\(msg)"
        }
    }
}

struct WPSPage {
    var total: Int?
    var items: [[String: Any]]
}

/// 直连 WPS AirScript（分页 + 日志兜底解析）
struct WPSClient {

    /// 拉取全部数据（自动翻页）
    static func pullAll(token: String,
                        fileId: String,
                        scriptId: String,
                        argv baseArgv: [String: Any],
                        pageSize: Int = 6000,
                        maxPages: Int = 80) async throws -> [[String: Any]] {
        var collected: [[String: Any]] = []
        var start = 0

        for _ in 0..<maxPages {
            var argv = baseArgv
            argv["start"] = start
            argv["count"] = pageSize

            let page = try await pullPage(token: token, fileId: fileId, scriptId: scriptId, argv: argv)
            if page.items.isEmpty { break }

            collected.append(contentsOf: page.items)
            start += page.items.count

            if let total = page.total, start >= total { break }
        }
        return collected
    }

    /// 拉取一页
    static func pullPage(token: String,
                         fileId: String,
                         scriptId: String,
                         argv: [String: Any]) async throws -> WPSPage {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty,
              !fileId.isEmpty, !scriptId.isEmpty else {
            throw WPSError.notConfigured
        }
        guard let url = URL(string: "https://www.kdocs.cn/api/v3/ide/file/\(fileId)/script/\(scriptId)/sync_task") else {
            throw WPSError.badPayload("地址拼不出来")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "AirScript-Token")
        request.setValue("inventory-app/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Context": ["argv": argv]])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data.prefix(240), encoding: .utf8) ?? ""
            throw WPSError.http(http.statusCode, body)
        }
        return try parse(data)
    }

    /// 解析返回：优先 data.result，拿不到就用 data.logs 里的 __C<n>__ 分片拼
    static func parse(_ data: Data) throws -> WPSPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WPSError.badPayload("返回不是 JSON")
        }
        if let err = root["error"] as? String, !err.isEmpty {
            throw WPSError.badPayload(err)
        }

        let dataObj = root["data"] as? [String: Any] ?? [:]
        var payload: [String: Any]?

        if let result = dataObj["result"] {
            if let dict = result as? [String: Any] {
                payload = dict
            } else if let text = result as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = trimmed.lowercased()
                if !["[undefined]", "undefined", "[null]", "null", ""].contains(lower),
                   let bytes = trimmed.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                    payload = dict
                }
            }
        }

        if payload == nil, let logs = dataObj["logs"] as? [[String: Any]] {
            payload = parseLogChunks(logs)
        }

        guard let dict = payload else {
            throw WPSError.badPayload("脚本没有返回值")
        }
        if let err = dict["__error"] as? String, !err.isEmpty {
            throw WPSError.badPayload(err)
        }

        let total = (dict["total"] as? NSNumber)?.intValue
        let items = dict["items"] as? [[String: Any]] ?? []
        return WPSPage(total: total, items: items)
    }

    /// 脚本把 JSON 切成 __C0__ / __C1__ … 打在日志里
    static func parseLogChunks(_ logs: [[String: Any]]) -> [String: Any]? {
        var chunks: [Int: String] = [:]
        let pattern = try? NSRegularExpression(pattern: "^__C(\\d+)__([\\s\\S]*)$")

        for log in logs {
            guard let args = log["args"] as? [Any] else { continue }
            for raw in args {
                let text = String(describing: raw).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, let regex = pattern else { continue }
                let ns = text as NSString
                let full = NSRange(location: 0, length: ns.length)
                guard let match = regex.firstMatch(in: text, range: full) else { continue }
                let idxText = ns.substring(with: match.range(at: 1))
                let body = ns.substring(with: match.range(at: 2))
                guard let idx = Int(idxText) else { continue }
                if let old = chunks[idx], old.count >= body.count { continue }
                chunks[idx] = body
            }
        }

        guard !chunks.isEmpty else { return nil }
        let joined = chunks.keys.sorted().compactMap { chunks[$0] }.joined()
        guard let data = joined.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
