import Foundation

/// DeepSeek 对话（只用于规则答不了的复杂问题）
struct DeepSeekClient {

    static let endpoint = "https://api.deepseek.com/v1/chat/completions"

    static func ask(question: String,
                    key: String,
                    context: String,
                    history: [ChatLine]) async throws -> String {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WPSError.badPayload("还没填 DeepSeek API Key")
        }
        guard let url = URL(string: endpoint) else {
            throw WPSError.badPayload("接口地址不对")
        }

        let system = """
        你是库存查询助手，必须称呼用户为「主人」，每次回答的第一句都要先叫一声「主人」。
        只能依据下面给出的数据回答，绝对不能编造编号或数字。
        数据里没有的，就直接说没找到。
        如果一条回答里有多个款，每个款占一行，格式：
        编号  价 X  库存 Y

        【当前数据】
        \(context)
        """

        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for line in history.suffix(6) {
            messages.append(["role": line.role, "content": line.text])
        }
        messages.append(["role": "user", "content": question])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "deepseek-chat",
            "messages": messages,
            "temperature": 0.2,
            "stream": false
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw WPSError.http(http.statusCode, body)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw WPSError.badPayload("接口返回看不懂")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
