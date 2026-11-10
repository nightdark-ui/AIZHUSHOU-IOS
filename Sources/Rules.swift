import Foundation

/// 本地规则引擎：编号直达的问题不用联网，毫秒级
enum Rules {

    /// 尝试用规则回答；返回 nil 表示规则答不了（交给 AI）
    static func answer(_ text: String,
                       products: [Product],
                       restock: [RestockItem],
                       threshold: Double) -> String? {

        let msg = normalize(text)
        guard !msg.isEmpty else { return nil }

        // 补货总览
        if msg.contains("补货") || msg.contains("要补") || msg.contains("缺货") {
            if let code = extractCodes(msg).first, let p = find(code, in: products) {
                return restockAdvice(p, threshold: threshold)
            }
            if restock.isEmpty {
                return "现在没有需要补货的款 👍"
            }
            var lines = ["需要补货的有 \(restock.count) 个款："]
            for item in restock.prefix(10) {
                lines.append(detailLine(item))
            }
            if restock.count > 10 { lines.append("……还有 \(restock.count - 10) 个") }
            return lines.joined(separator: "\n")
        }

        // 「有没有300」「够300吗」
        if let need = thresholdNumber(msg), let p = findAny(msg, in: products) {
            return thresholdAnswer(p, need: need)
        }

        let codes = extractCodes(msg)
        guard !codes.isEmpty else { return nil }

        // 多个编号
        if codes.count >= 2 {
            var lines: [String] = []
            var missing: [String] = []
            for code in codes {
                if let p = find(code, in: products) {
                    lines.append("\(p.sku)  \(priceText(p))  \(stockText(p))")
                } else {
                    missing.append(code)
                }
            }
            if lines.isEmpty { return nil }
            var out = lines.joined(separator: "\n")
            if !missing.isEmpty { out += "\n另外 \(missing.joined(separator: "、")) 没找到。" }
            return out
        }

        // 单个编号
        let code = codes[0]
        guard let p = find(code, in: products) else { return nil }

        if msg.contains("价格") || msg.contains("多少钱") || msg.contains("价") {
            return "\(p.sku) \(priceText(p))"
        }
        if msg.contains("图片") || msg.contains("照片") {
            return "图片功能还没做，先看文字吧。"
        }
        return stockText(p)
    }

    // MARK: - 回答片段

    static func priceText(_ p: Product) -> String {
        guard let t = p.priceText, !t.isEmpty else { return "价格表里没填" }
        return "价格 \(t)"
    }

    static func stockText(_ p: Product) -> String {
        guard let q = p.qty else {
            if let t = p.qtyText, !t.isEmpty { return "表格里写的是「\(t)」，算不出数量" }
            return "表格里没填数量"
        }
        if q <= 0 { return "目前没货" }
        return "还有 " + amount(p, total: q) + " 码"
    }

    /// 有算式就带上明细：96+103+95+117+166 = 577
    static func amount(_ p: Product, total: Double) -> String {
        let raw = (p.qtyText ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, Double(raw) == nil else {
            return "\(Int(total))"
        }
        return "\(raw) = \(Int(total))"
    }

    static func detailLine(_ item: RestockItem) -> String {
        let qty = item.qty.map { Int($0) } ?? 0
        return "· \(item.sku)  少了 \(Int(abs(item.change)))  剩 \(qty)"
    }

    static func restockAdvice(_ p: Product, threshold: Double) -> String {
        guard let q = p.qty else { return "\(p.sku) 的数量算不出来，请按表格判断。" }
        let limit = p.minQty ?? threshold
        let detail = amount(p, total: q)
        if q <= 0 { return "\(p.sku) 没货了，需要补。" }
        if q < limit { return "\(p.sku) 还有 \(detail) 码，低于提醒线 \(Int(limit))，建议补。" }
        return "\(p.sku) 还有 \(detail) 码，高于提醒线 \(Int(limit))，暂时不用补。"
    }

    static func thresholdAnswer(_ p: Product, need: Double) -> String {
        guard let q = p.qty else {
            return "\(p.sku) 的数量写的是「\(p.qtyText ?? "")」，算不出来，判断不了够不够 \(Int(need))。"
        }
        let n = Int(need)
        let detail = amount(p, total: q)
        if q <= 0 { return "\(p.sku) 没货，不够 \(n) 码。" }
        if q >= need { return "\(p.sku) 还有 \(detail) 码，够 \(n)。" }
        return "\(p.sku) 只剩 \(detail) 码，不够 \(n)（差 \(Int(need - q)) 码）。"
    }

    // MARK: - 文本处理

    static func normalize(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "，", with: ",")
        s = s.replacingOccurrences(of: "？", with: "?")
        s = s.replacingOccurrences(of: "！", with: "!")
        return s
    }

    /// 抽出消息里像编号的词（数字/字母组合）
    static func extractCodes(_ text: String) -> [String] {
        // 去掉「有没有300」「够300吗」里的数字，避免当成编号
        var work = text
        let pattern = "^(.*?)(有没有|够不够|够|有|到|超过|大于|至少)\\s*\\d{2,6}\\s*(码|米)?\\s*(吗|么|呢)?$"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let m = regex.firstMatch(in: work, range: NSRange(work.startIndex..., in: work)),
           let r = Range(m.range(at: 1), in: work) {
            work = String(work[r])
        }

        var found: [String] = []
        let codeRegex = try? NSRegularExpression(pattern: "[A-Za-z]{0,6}[0-9]{1,8}(?:[-_][0-9]{1,4})?[\\u4e00-\\u9fa5]{0,4}")
        if let regex = codeRegex {
            let ns = work as NSString
            let matches = regex.matches(in: work, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                var s = ns.substring(with: m.range)
                s = s.trimmingCharacters(in: .whitespaces)
                if s.count < 2 { continue }
                if s.allSatisfy({ $0.isNumber }) && s.count < 3 { continue }
                if !found.contains(s) { found.append(s) }
            }
        }
        return found
    }

    static func thresholdNumber(_ text: String) -> Double? {
        let pattern = "(?:有没有|够不够|够|有|到|超过|大于|至少)\\s*(\\d{2,6})\\s*(?:码|米)?\\s*(?:吗|么|呢)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let numText = ns.substring(with: m.range(at: 1))
        return Double(numText)
    }

    static func find(_ code: String, in products: [Product]) -> Product? {
        let target = code.uppercased()
        if let exact = products.first(where: { $0.sku.uppercased() == target }) { return exact }
        // 忽略括号/中文后缀的近似
        return products.first { $0.sku.uppercased().hasPrefix(target) }
    }

    static func findAny(_ text: String, in products: [Product]) -> Product? {
        let codes = extractCodes(text)
        for c in codes {
            if let p = find(c, in: products) { return p }
        }
        // 「2002有没有300」这类：取开头那段
        let head = text.split(whereSeparator: { "有没有够到超过大于至少码吗么呢? ".contains($0) }).first
        if let h = head {
            let s = String(h).trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, let p = find(s, in: products) { return p }
        }
        return nil
    }
}
