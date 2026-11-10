import Foundation

/// DeepSeek 对话（只用于规则答不了的复杂问题）
struct DeepSeekClient {

    static let defaultBase = "https://api.deepseek.com/v1"

    static func ask(question: String,
                    key: String,
                    context: String,
                    history: [ChatLine],
                    base: String = defaultBase,
                    model: String = "deepseek-chat") async throws -> String {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WPSError.badPayload("还没填 DeepSeek API Key")
        }
        var root = base.trimmingCharacters(in: .whitespaces)
        if root.isEmpty { root = defaultBase }
        if root.hasSuffix("/") { root.removeLast() }
        guard let url = URL(string: root + "/chat/completions") else {
            throw WPSError.badPayload("接口地址不对")
        }

        let system = """
        你是库存查询助手，必须称呼用户为「主人」，每次回答的第一句都要先叫一声「主人」。
        只能依据下面给出的数据回答，绝对不能编造编号或数字。
        数据里没有的，就直接说没找到。
        价格和库存必须分成两行写，不要挤在一行。
        多条回答时，每个款下面写：
        编号
        价格 X
        库存 Y

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
            "model": model,
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


    // MARK: - 带工具调用（让 AI 自己查库存）

    /// 返回 (回答, 证据)；证据用于数字校验
    static func askWithTools(question: String,
                             key: String,
                             history: [ChatLine],
                             base: String,
                             model: String,
                             products: [Product],
                             restock: [RestockItem],
                             extraInstruction: String = "") async throws -> (text: String, evidence: String) {

        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WPSError.badPayload("还没填 DeepSeek API Key")
        }
        var root = base.trimmingCharacters(in: .whitespaces)
        if root.isEmpty { root = defaultBase }
        if root.hasSuffix("/") { root.removeLast() }
        guard let url = URL(string: root + "/chat/completions") else {
            throw WPSError.badPayload("接口地址不对")
        }

        let system = """
        你是库存查询助手，必须称呼用户为「主人」，每次回答的第一句都要先叫一声「主人」。
        回答库存和价格时，只能用工具返回的数据，绝对不能编造编号或数字。
        工具没查到的，就直说没找到。
        价格和库存分两行写，不要挤在一行。
        多个款时每个款单独一段，格式：
        编号
        价格 X
        库存 Y 码
        \(extraInstruction)
        """

        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for line in history.suffix(6) where line.role == "user" || line.role == "assistant" {
            messages.append(["role": line.role, "content": line.text])
        }
        messages.append(["role": "user", "content": question])

        var evidence = ""

        for _ in 0..<4 {
            var body: [String: Any] = [
                "model": model,
                "messages": messages,
                "temperature": 0.2,
                "stream": false
            ]
            body["tools"] = AITools.definitions
            body["tool_choice"] = "auto"

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
                throw WPSError.http(http.statusCode, text)
            }
            guard let rootObj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = rootObj["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                throw WPSError.badPayload("接口返回看不懂")
            }

            let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
            if toolCalls.isEmpty {
                let content = (message["content"] as? String) ?? ""
                return (content.trimmingCharacters(in: .whitespacesAndNewlines), evidence)
            }

            // 执行工具
            var assistantMsg: [String: Any] = ["role": "assistant", "content": message["content"] ?? ""]
            assistantMsg["tool_calls"] = toolCalls
            messages.append(assistantMsg)

            for call in toolCalls {
                let fn = call["function"] as? [String: Any] ?? [:]
                let name = (fn["name"] as? String) ?? ""
                let argText = (fn["arguments"] as? String) ?? "{}"
                var args: [String: Any] = [:]
                if let d = argText.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    args = obj
                }
                let result = AITools.run(name: name, arguments: args,
                                         products: products, restock: restock)
                evidence += result + "\n"
                messages.append([
                    "role": "tool",
                    "tool_call_id": (call["id"] as? String) ?? "",
                    "content": result
                ])
            }
        }

        throw WPSError.badPayload("AI 查询次数过多，请换个问法")
    }
}
