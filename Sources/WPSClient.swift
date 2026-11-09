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

/// 直连 WPS AirScript
struct WPSClient {

    /// 拉取一列数据（默认 mode=codes，返回编号 + 数量/单价）
    static func pull(token: String,
                     fileId: String,
                     scriptId: String,
                     argv: [String: Any] = ["mode": "codes"]) async throws -> [[String: Any]] {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty,
              !fileId.isEmpty, !scriptId.isEmpty else {
            throw WPSError.notConfigured
        }

        guard let url = URL(string: "https://www.kdocs.cn/api/v3/ide/file/\(fileId)/script/\(scriptId)") else {
            throw WPSError.badPayload("地址拼不出来")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "AirScript-Token")
        request.setValue("AIZhushou/0.1 (iPhone)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Context": ["argv": argv]])

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data.prefix(240), encoding: .utf8) ?? ""
            throw WPSError.http(http.statusCode, body)
        }

        return try parseItems(data)
    }

    /// 解析 AirScript 的返回（result 可能是对象，也可能是 JSON 字符串）
    static func parseItems(_ data: Data) throws -> [[String: Any]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WPSError.badPayload("返回不是 JSON")
        }
        if let err = root["error"] as? String, !err.isEmpty {
            throw WPSError.badPayload(err)
        }
        if let status = root["status"] as? String, status != "finished" {
            throw WPSError.badPayload("脚本状态 \(status)")
        }

        guard let result = (root["data"] as? [String: Any])?["result"] else {
            throw WPSError.badPayload("脚本没有返回值")
        }

        var payload: [String: Any]?
        if let dict = result as? [String: Any] {
            payload = dict
        } else if let text = result as? String,
                  let d = text.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            payload = dict
        }

        guard let dict = payload else {
            throw WPSError.badPayload("结果不是 JSON 对象")
        }
        if let err = dict["error"] as? String, !err.isEmpty {
            throw WPSError.badPayload(err)
        }

        if let items = dict["items"] as? [[String: Any]] {
            return items
        }
        if let values = dict["values"] as? [Any] {
            return values.map { ["编号": $0] }
        }
        return []
    }
}
