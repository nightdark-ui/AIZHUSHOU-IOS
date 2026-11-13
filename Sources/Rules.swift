import Foundation

/// 上一轮的状态（用于「还有别的吗」）
struct RuleTurn {
    var kind = ""          // "price" / "choose"
    var low: Double = 0
    var high: Double = 0
    var shown: Int = 0
    var options: [String] = []
    var intent = ""   // 选项对应的意图：price / stock
}

/// 本地规则引擎：编号直达、区间、筛选、补货，毫秒级
enum Rules {

    static let pageSize = 30
    static let yardToMeter = 0.9144

    // MARK: - 入口

    static func answer(_ text: String,
                       products: [Product],
                       restock: [RestockItem],
                       threshold: Double,
                       turn: RuleTurn?) -> (text: String?, turn: RuleTurn?) {

        let msg = normalize(text)
        guard !msg.isEmpty else { return (nil, turn) }
        let wantMeters = wantsMeters(msg)

        // 0. 追问：还有别的吗 / 换一批 N 个
        if let t = turn, t.kind == "price", isFollowUp(msg) {
            return pricePage(t, products: products, size: followUpCount(msg) ?? pageSize)
        }

        // 1. 闲聊
        if let chat = chitchat(msg, productCount: products.count) {
            return (chat, nil)
        }
        // 1b. 离题
        if let off = offtopic(msg) {
            return (off, nil)
        }
        // 1c. 总览统计
        if let ov = overviewReply(msg, products: products, restock: restock) {
            return (ov, nil)
        }
        // 1d. 比较（比 2053 贵的 / 比 2053 便宜的 2 开头的）
        if let cmp = comparison(msg, products: products) {
            return (cmp, nil)
        }
        // 1e. 价格区间
        if let pr = priceRange(msg) {
            return pricePage(RuleTurn(kind: "price", low: pr.0, high: pr.1), products: products, size: pageSize)
        }
        // 1f. 编号区间（可带价格/库存条件）
        if let cr = codeRange(msg, products: products), !cr.skus.isEmpty {
            var pool = cr.skus
            var condText: [String] = []
            if let pr = priceRange(msg) {
                pool = pool.filter { p in
                    guard let v = p.price else { return false }
                    return v >= pr.0 && v <= pr.1
                }
                condText.append("价格 \(intText(pr.0))–\(intText(pr.1))")
            }
            if let qmin = qtyMinCondition(msg) {
                pool = pool.filter { ($0.qty ?? -1) >= qmin }
                condText.append("库存 ≥ \(Int(qmin))")
            }
            if let qmax = qtyMaxCondition(msg) {
                pool = pool.filter { p in
                    guard let q = p.qty else { return false }
                    return q <= qmax
                }
                condText.append("库存 ≤ \(Int(qmax))")
            }
            if pool.isEmpty {
                return ("\(cr.from)–\(cr.to) 里没有符合条件的款。", nil)
            }
            let extra = condText.isEmpty ? "" : "（\(condText.joined(separator: "、"))）"
            var lines = ["\(cr.from)–\(cr.to) 共 \(cr.skus.count) 个，符合条件 \(pool.count) 个\(extra)："]
            for p in pool.prefix(40) { lines.append("· \(p.sku)  " + qtyBrief(p)) }
            if pool.count > 40 { lines.append("……还有 \(pool.count - 40) 个") }
            return (lines.joined(separator: "\n"), nil)
        }

        // 2. 补货
        if isRestockAsk(msg) {
            let lead = extractCodes(msg).first.flatMap { resolve($0, in: products) }
            if let p = lead { return (restockAdvice(p, threshold: threshold), nil) }
            if restock.isEmpty { return ("现在没有需要补货的款 👍", nil) }
            var lines = ["需要补货的有 \(restock.count) 个款："]
            for item in restock.prefix(10) { lines.append(detailLine(item)) }
            if restock.count > 10 { lines.append("……还有 \(restock.count - 10) 个") }
            return (lines.joined(separator: "\n"), nil)
        }

        // 3. 数量筛选列表（超过 300 米的 / 2 开头的超过 300 米）
        if let list = qtyListReply(msg, products: products) {
            return (list, nil)
        }

        // 4. 够不够 / 有没有货（单个编号优先）
        if let th = thresholdQuestion(msg) {
            let code = th.code ?? extractCodes(msg).first
            if let code, let p = resolve(code, in: products) {
                if let need = th.need {
                    return (thresholdAnswer(p, need: need) + metersSuffix(p, want: wantMeters), nil)
                }
                return (stockYesNo(p), nil)
            }
            if th.need == nil {
                return ("要问哪个编号？比如「2002 有没有货」或「2053 有没有300」。", nil)
            }
            if code == nil {
                return ("要问哪个编号？比如「2002 有没有\(Int(th.need ?? 0))」或「SL1004 够\(Int(th.need ?? 0))吗」。", nil)
            }
        }

        // 5. 普通编号查询
        let codes = extractCodes(msg)
        guard !codes.isEmpty else { return (nil, nil) }

        if codes.count >= 2 {
            // 问价格就只说价格，问库存就只说库存
            let asksPrice = msg.contains("价") || msg.contains("多少钱")
            let asksStock = msg.contains("库存") || msg.contains("还有") || msg.contains("剩")
                || msg.contains("码") || msg.contains("米") || msg.contains("数量")
            let both = asksPrice && asksStock

            var lines: [String] = []
            var missing: [String] = []
            for code in codes {
                if let p = resolve(code, in: products) {
                    if !lines.isEmpty { lines.append("") }
                    let price = p.priceText?.isEmpty == false ? p.priceText! : "未填"
                    lines.append(p.sku)
                    if asksPrice || both {
                        lines.append("价格 \(price)")
                    }
                    if asksStock || both {
                        if let q = p.qty {
                            let raw = (p.qtyText ?? "").trimmingCharacters(in: .whitespaces)
                            lines.append("库存 \(Int(q)) 码")
                            if !raw.isEmpty, Double(raw) == nil { lines.append("（\(raw)）") }
                        } else if let t = p.qtyText, !t.isEmpty {
                            lines.append("数量算不出来（表格写「\(t)」）")
                        } else {
                            lines.append("数量未填")
                        }
                    }
                } else {
                    missing.append(code)
                }
            }
            if lines.isEmpty {
                if let sug = suggestion(missing.first ?? "", products: products) { return (sug, nil) }
                return (nil, nil)
            }
            var out = lines.joined(separator: "\n")
            if !missing.isEmpty { out += "\n\n另外 \(missing.joined(separator: "、")) 没找到。" }
            return (out, nil)
        }

        // 6. 单个编号
        let code = codes[0]

        // 6a. 编号 + 说明（9005 32梭）
        if let exact = resolveWithSuffix(code: code, message: msg, products: products) {
            return (stockLine(exact, wantMeters: wantMeters), nil)
        }

        // 6b. 多种写法 / 前缀多个 → 让用户点选
        let variants = variantList(code, in: products)
        let asksSpecific = msg.contains("价格") || msg.contains("多少钱") || msg.contains("价")
            || msg.contains("库存") || msg.contains("还有") || msg.contains("剩")
            || msg.contains("米") || msg.contains("图片") || msg.contains("照片")

        if variants.count > 1 && !asksSpecific {
            var turn = RuleTurn(kind: "choose")
            turn.options = variants.prefix(8).map { $0.sku }
            turn.intent = msg.contains("价格") || msg.contains("多少钱") ? "price" : "stock"
            return ("「\(code)」有 \(variants.count) 种写法，点下面选一个：", turn)
        }

        guard let p = resolve(code, in: products) else {
            if let sug = suggestion(code, products: products) { return (sug, nil) }
            return ("没找到「\(code)」。可以说完整编号（比如 2002），或者问「2001-2010 库存」。", nil)
        }

        // 6c. 图片
        if msg.contains("图片") || msg.contains("照片") || msg.contains("长什么样") {
            return ("\(p.sku) 的图片：", nil)
        }

        // 6d. 价格 / 库存 / 两者
        let asksPrice = msg.contains("价格") || msg.contains("多少钱") || msg.contains("价")
        let asksStock = msg.contains("库存") || msg.contains("还剩") || msg.contains("还有")
            || msg.contains("够") || msg.contains("码") || msg.contains("米") || msg.contains("几米")
        let price = p.priceText?.isEmpty == false ? p.priceText! : "未填"

        if asksPrice && asksStock {
            var lines = [p.sku, "价格 \(price)"]
            if let q = p.qty {
                let raw = (p.qtyText ?? "").trimmingCharacters(in: .whitespaces)
                lines.append("库存 \(Int(q)) 码")
                if !raw.isEmpty, Double(raw) == nil { lines.append("（\(raw)）") }
            } else {
                lines.append(stockText(p))
            }
            return (lines.joined(separator: "\n") + metersSuffix(p, want: wantMeters), nil)
        }
        if asksPrice {
            return ("\(p.sku)  价格 \(price)", nil)
        }
        return (stockLine(p, wantMeters: wantMeters), nil)
    }

    // MARK: - 编号解析

    /// 归一化：全角转半角、标点统一
    static func normalize(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 全角数字/字母
        let full = "０１２３４５６７８９ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ"
        let half = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        let fm = Array(full), hm = Array(half)
        var mapped = ""
        for ch in s {
            if let idx = fm.firstIndex(of: ch) { mapped.append(hm[idx]) } else { mapped.append(ch) }
        }
        s = mapped
        s = s.replacingOccurrences(of: "，", with: ",")
        s = s.replacingOccurrences(of: "？", with: "?")
        s = s.replacingOccurrences(of: "！", with: "!")
        s = s.replacingOccurrences(of: "．", with: ".")
        s = s.replacingOccurrences(of: "、", with: ",")
        s = s.replacingOccurrences(of: "（", with: "(")
        s = s.replacingOccurrences(of: "）", with: ")")
        s = s.replacingOccurrences(of: "：", with: ":")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s
    }

    /// 句子里像编号的词（已去掉助词、提问词）
    static func extractCodes(_ text: String) -> [String] {
        var work = normalize(text)

        // 去掉「够不够/有没有 + 数字」里的数字，避免当成编号
        let dropThreshold = "(?:有没有|够不够|够|有)\\s*\\d{1,6}\\s*(?:码|米|m|M|打|包)?"
        work = work.replacingOccurrences(of: dropThreshold, with: " ", options: .regularExpression)
        work = work.replacingOccurrences(of: "\\d{1,6}\\s*(?:码|米|m|M)?\\s*(?:有吗|有没有|有么)",
                                         with: " ", options: .regularExpression)

        var found: [String] = []
        let pattern = "[A-Za-z]{0,6}\\d{1,8}(?:[-_][0-9]{1,4})?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = work as NSString
        var ranges: [NSRange] = []
        for m in regex.matches(in: work, range: NSRange(location: 0, length: ns.length)) {
            ranges.append(m.range)
        }

        for r in ranges {
            var token = ns.substring(with: r)
            // 去掉纯数字且太短的
            let digits = token.filter { $0.isNumber }
            if token.allSatisfy({ $0.isNumber }) && digits.count < 2 { continue }
            // 去掉句子里紧跟着中文的编号后缀（2053呢 → 2053）
            var endIndex = r.location + r.length
            while endIndex < ns.length {
                let ch = ns.substring(with: NSRange(location: endIndex, length: 1))
                if isChinese(ch) { endIndex += 1 } else { break }
            }
            let withSuffix = ns.substring(with: NSRange(location: r.location, length: endIndex - r.location))
            token = cleanToken(withSuffix)
            if token.count < 2 { continue }
            if !found.contains(where: { $0.uppercased() == token.uppercased() }) {
                found.append(token)
            }
        }
        return found
    }

    /// 去掉粘在编号上的助词/提问词
    static func cleanToken(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "?:!,.;"))
        let tails = ["有没有货", "有货吗", "有没有", "够不够", "多少钱", "多少米", "多少码",
                     "多少钱", "价格", "库存", "还有多少", "还有", "剩多少", "剩", "有货",
                     "够吗", "够", "几米", "码", "米", "款", "货", "的", "呢", "吗", "啊",
                     "吧", "么", "呀", "了", "是", "和", "帮", "我", "查", "看", "找", "问"]
        var changed = true
        while changed {
            changed = false
            for t in tails where s.hasSuffix(t) && s.count > t.count {
                s = String(s.dropLast(t.count))
                changed = true
            }
        }
        // 前缀口语词
        let heads = ["帮我", "给我", "看看", "看下", "查下", "查一下", "问下", "我想", "请"]
        for h in heads where s.hasPrefix(h) && s.count > h.count {
            s = String(s.dropFirst(h.count))
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func isChinese(_ s: String) -> Bool {
        guard let scalar = s.unicodeScalars.first, s.unicodeScalars.count == 1 else { return false }
        return scalar.value >= 0x4E00 && scalar.value <= 0x9FA5
    }

    /// 找到具体的款：精确 → 去中文尾 → 前缀 → 括号片段 → 包含
    static func resolve(_ code: String, in products: [Product]) -> Product? {
        var t = code.uppercased()
        if let exact = products.first(where: { $0.sku.uppercased() == t }) { return exact }

        // 去掉中文尾巴逐个试（2053密 → 2053）
        while let last = t.last, isChinese(String(last)) {
            t.removeLast()
            guard !t.isEmpty else { break }
            if let exact = products.first(where: { $0.sku.uppercased() == t }) { return exact }
        }

        let base = t
        if let pref = products.first(where: { $0.sku.uppercased().hasPrefix(base) }) { return pref }

        // 括号里的片段：A78 → SL5006(A78)
        if base.count >= 2 {
            if let hit = products.first(where: { p in
                let s = p.sku.uppercased()
                return s.contains("(\(base)") || s.contains("\(base))")
            }) { return hit }
        }

        // 包含
        if base.count >= 3, let hit = products.first(where: { $0.sku.uppercased().contains(base) }) {
            return hit
        }
        return nil
    }

    /// 兼容旧名字
    static func find(_ code: String, in products: [Product]) -> Product? {
        resolve(code, in: products)
    }

    /// 同一编号的不同写法（含中文后缀、括号）
    static func variantList(_ code: String, in products: [Product]) -> [Product] {
        let t = code.uppercased()
        let junk = ["库存", "价格", "多少钱", "还有", "多少", "剩", "款", "货"]
        return products.filter { p in
            let s = p.sku.uppercased()
            if s == t { return true }
            guard s.hasPrefix(t) else { return false }
            let rest = String(s.dropFirst(t.count))
            guard let first = rest.first else { return false }
            if first == "-" || first == "_" || first == "(" { return true }
            if isChinese(String(first)) {
                // 排除「2053库存」这种
                return !junk.contains(where: { rest.hasPrefix($0) })
            }
            return false
        }
    }

    /// 编号 + 说明：9005 32梭 → 9005(32梭)
    static func resolveWithSuffix(code: String, message: String, products: [Product]) -> Product? {
        let variants = variantList(code, in: products)
        guard variants.count > 1 else { return nil }

        let rest = message.replacingOccurrences(of: code, with: "")
        let normalized = rest.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        guard !normalized.isEmpty else { return nil }

        var hits: [Product] = []
        for v in variants {
            let suffix = v.sku.uppercased()
                .replacingOccurrences(of: code.uppercased(), with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
            guard !suffix.isEmpty else { continue }
            if normalized.contains(suffix) { hits.append(v) }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    static func suggestion(_ code: String, products: [Product]) -> String? {
        let near = suggest(code, in: products)
        guard !near.isEmpty else { return nil }
        var lines = ["没找到「\(code)」。是不是这些："]
        for n in near { lines.append("· \(n.sku)  \(stockText(n))") }
        lines.append("（直接发编号就行）")
        return lines.joined(separator: "\n")
    }

    static func suggest(_ code: String, in products: [Product], limit: Int = 5) -> [Product] {
        let target = code.uppercased()
        guard target.count >= 3 else { return [] }
        var scored: [(Product, Int)] = []
        for p in products {
            let s = p.sku.uppercased()
            var common = 0
            for (a, b) in zip(target, s) {
                if a == b { common += 1 } else { break }
            }
            let tDigits = target.filter { $0.isNumber }
            let sDigits = s.filter { $0.isNumber }
            var dCommon = 0
            for (a, b) in zip(tDigits, sDigits) {
                if a == b { dCommon += 1 } else { break }
            }
            let score = max(common, dCommon)
            if score >= 3 { scored.append((p, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    // MARK: - 够不够 / 有没有货

    /// 返回 (编号, 数量, 是否只是问有没有货)
    static func thresholdQuestion(_ msg: String) -> (code: String?, need: Double?, isStockYesNo: Bool)? {
        let hasAsk = msg.contains("有没有") || msg.contains("够不够") || msg.contains("够")
            || msg.contains("有吗") || msg.contains("有么") || msg.contains("有货")
            || msg.contains("有没有货")
        guard hasAsk else { return nil }

        // (有没有|够不够|够|有) + 数字
        var need: Double? = nil
        let patterns = [
            "(?:有没有|够不够|够|有)\\s*(\\d{1,6})\\s*(码|米|m|M|打|包)?",
            "(\\d{1,6})\\s*(码|米|m|M|打|包)?\\s*(?:有吗|有么|有没有|够吗)"
        ]
        for pat in patterns where need == nil {
            guard let regex = try? NSRegularExpression(pattern: pat) else { continue }
            let ns = msg as NSString
            if let m = regex.firstMatch(in: msg, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1,
               let v = Double(ns.substring(with: m.range(at: 1))) {
                var unit = ""
                if m.numberOfRanges > 2, m.range(at: 2).location != NSNotFound {
                    unit = ns.substring(with: m.range(at: 2)).lowercased()
                }
                need = (unit == "米" || unit == "m") ? v * 1.09361 : v
            }
        }

        let codes = extractCodes(msg)
        let code = codes.first
        if need == nil {
            // 只问有没有货
            if msg.contains("有货") || msg.contains("有没有货") || msg.contains("有吗") || msg.contains("有么") {
                return (code, nil, true)
            }
            return nil
        }
        // 数字被误当成编号的情况（"2002 400有吗"）
        if let c = code, let n = need, c == String(Int(n)) {
            return (codes.count > 1 ? codes[1] : nil, n, false)
        }
        return (code, need, false)
    }

    // MARK: - 回答片段

    static func stockYesNo(_ p: Product) -> String {
        guard let q = p.qty else {
            if let t = p.qtyText, !t.isEmpty { return "\(p.sku) 的数量写的是「\(t)」，算不出来。" }
            return "\(p.sku) 表格里没填数量。"
        }
        return q > 0 ? "\(p.sku) 有货，还有 \(amount(p, total: q)) 码。" : "\(p.sku) 没货。"
    }

    static func stockLine(_ p: Product, wantMeters: Bool) -> String {
        p.sku + " " + stockText(p) + metersSuffix(p, want: wantMeters)
    }

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

    static func amount(_ p: Product, total: Double) -> String {
        let raw = (p.qtyText ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, Double(raw) == nil else { return "\(Int(total))" }
        return "\(raw) = \(Int(total))"
    }

    static func qtyBrief(_ p: Product) -> String {
        guard let q = p.qty else {
            if let t = p.qtyText, !t.isEmpty { return "「\(t)」" }
            return "没填"
        }
        if q <= 0 { return "0" }
        let raw = (p.qtyText ?? "").trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty, Double(raw) == nil { return "\(raw) = \(Int(q))" }
        return "\(Int(q))"
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

    // MARK: - 米 / 码

    static func wantsMeters(_ msg: String) -> Bool {
        (msg.contains("米") || msg.contains("m") || msg.contains("几米")) && !msg.contains("码")
    }

    static func metersSuffix(_ p: Product, want: Bool) -> String {
        guard want, let q = p.qty, q > 0 else { return "" }
        return "\n" + metersText(q)
    }

    static func metersText(_ yards: Double) -> String {
        let meters = yards * yardToMeter
        let text = abs(meters - meters.rounded()) < 0.5
            ? String(format: "%.0f", meters)
            : String(format: "%.1f", meters)
        return "（\(Int(yards)) 码 ≈ \(text) 米，1 码 = 0.9144 米）"
    }

    // MARK: - 闲聊 / 离题

    static func chitchat(_ msg: String, productCount: Int) -> String? {
        let greetings = ["你好", "您好", "在吗", "在不在", "hi", "hello", "哈喽", "早上好", "晚上好", "下午好"]
        let thanks = ["谢谢", "多谢", "感谢", "辛苦"]
        let who = ["你是谁", "你叫什么", "你能干什么", "你会什么", "怎么用"]

        if who.contains(where: { msg.contains($0) }) {
            return "我是你的库存小助手。可以这样问我：\n· 2002 库存\n· 2053 有没有300\n· 2053 有没有货\n· 2001-2010 库存\n· 超过300米 2开头的有哪些\n· 10元左右的花\n· 有什么要补货的"
        }
        if thanks.contains(where: { msg.contains($0) }) { return "不客气，主人。" }
        if greetings.contains(where: { msg.lowercased() == $0 || msg.lowercased().hasPrefix($0) }) {
            if productCount == 0 { return "主人好！我还没有数据，先去「设置」同步一次吧。" }
            return "主人好！我是 AI 小助手，可以帮主人查库存、查价格、看补货。"
        }
        return nil
    }

    static func offtopic(_ msg: String) -> String? {
        let keys = ["天气", "新闻", "股票", "汇率", "比特币", "笑话", "唱歌", "讲故事",
                    "写代码", "编程", "翻译", "作文", "电影", "歌曲", "游戏", "几点了"]
        guard keys.contains(where: { msg.contains($0) }) else { return nil }
        let business = ["库存", "价格", "多少钱", "补货", "码", "款号"]
        if business.contains(where: { msg.contains($0) }) { return nil }
        return "这个我帮不上忙，我只会查库存、查价格、看补货。"
    }

    // MARK: - 总览

    static func overviewReply(_ msg: String, products: [Product], restock: [RestockItem]) -> String? {
        let keys = ["总览", "整体", "一共", "总共", "多少种", "多少个款", "统计", "销量", "卖得", "情况"]
        guard keys.contains(where: { msg.contains($0) }) else { return nil }

        let total = products.count
        let withQty = products.filter { $0.qty != nil }.count
        let zero = products.filter { ($0.qty ?? 1) <= 0 && $0.qty != nil }.count
        let withPrice = products.filter { $0.price != nil }.count

        var lines: [String] = []
        lines.append("一共 \(total) 个款，其中 \(withQty) 个有数量、\(withPrice) 个有价格。")
        lines.append("没货的 \(zero) 个。")
        lines.append(restock.isEmpty ? "今天没有需要补的。" : "今天需要补的 \(restock.count) 个。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 条件

    static func qtyMinCondition(_ msg: String) -> Double? {
        let patterns = [
            "(?:库存|数量)\\s*(?:超过|大于|高于|多于|至少)\\s*(\\d{1,6})",
            "(\\d{1,6})\\s*(?:码|米)?\\s*(?:以上|起|往上)"
        ]
        for pat in patterns {
            guard let regex = try? NSRegularExpression(pattern: pat) else { continue }
            let ns = msg as NSString
            if let m = regex.firstMatch(in: msg, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1, let v = Double(ns.substring(with: m.range(at: 1))) {
                return v
            }
        }
        return nil
    }

    static func qtyMaxCondition(_ msg: String) -> Double? {
        let patterns = [
            "(?:库存|数量)\\s*(?:少于|小于|低于|不足|不到)\\s*(\\d{1,6})",
            "(\\d{1,6})\\s*(?:码|米)?\\s*(?:以下|以内)"
        ]
        for pat in patterns {
            guard let regex = try? NSRegularExpression(pattern: pat) else { continue }
            let ns = msg as NSString
            if let m = regex.firstMatch(in: msg, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1, let v = Double(ns.substring(with: m.range(at: 1))) {
                return v
            }
        }
        return nil
    }

    static func prefixFilter(_ msg: String) -> String? {
        let pattern = "(\\d)\\s*开头"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = msg as NSString
        guard let m = regex.firstMatch(in: msg, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func isRestockAsk(_ msg: String) -> Bool {
        msg.contains("补货") || msg.contains("要补") || msg.contains("缺货") || msg.contains("断货")
    }

    // MARK: - 数量筛选

    static func qtyListReply(_ msg: String, products: [Product]) -> String? {
        // 有具体编号的，交给"够不够"处理，不算筛选
        if let c = extractCodes(msg).first, resolve(c, in: products) != nil { return nil }

        let prefix = prefixFilter(msg)
        let wantsList = msg.contains("哪些") || msg.contains("那些") || msg.contains("有没")
            || msg.contains("哪些款") || msg.contains("的款") || msg.contains("的花")
            || msg.contains("的有") || msg.contains("有的")

        // 阈值：超过/大于/以上/不少于/有/库存/达到 + 数字
        var threshold: Double? = nil
        var unit = ""

        let patterns = [
            "(?:超过|大于|多于|不少于|至少|达到|有|库存|数量)\\s*(\\d{1,6})\\s*(米|m|M|码|打|包)?",
            "(\\d{1,6})\\s*(米|m|M|码|打|包)?\\s*(?:以上|起|往上|的有|的款)"
        ]
        for pat in patterns where threshold == nil {
            guard let regex = try? NSRegularExpression(pattern: pat) else { continue }
            let ns = msg as NSString
            if let m = regex.firstMatch(in: msg, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1,
               let v = Double(ns.substring(with: m.range(at: 1))), v >= 1 {
                threshold = v
                if m.numberOfRanges > 2, m.range(at: 2).location != NSNotFound {
                    unit = ns.substring(with: m.range(at: 2)).lowercased()
                }
            }
        }

        guard let raw = threshold else { return nil }
        guard wantsList || prefix != nil || msg.contains("超过") || msg.contains("以上") else { return nil }

        // 米 → 码
        let yards = (unit == "米" || unit == "m") ? raw * 1.09361 : raw

        let pool = products.filter { p in
            guard let q = p.qty else { return false }
            if q < yards { return false }
            if let pre = prefix, !p.sku.hasPrefix(pre) { return false }
            return true
        }.sorted { ($0.qty ?? 0) > ($1.qty ?? 0) }

        let unitText = (unit == "米" || unit == "m")
            ? "\(intText(raw)) 米（约 \(Int(yards)) 码）"
            : "\(intText(raw)) 码"
        let prefixText = prefix.map { "\($0) 开头的" } ?? ""

        guard !pool.isEmpty else { return "没有\(prefixText)库存 \(unitText) 以上的款。" }

        var lines = ["\(prefixText)库存 \(unitText) 以上的共 \(pool.count) 款，先列 \(min(pool.count, 30)) 个："]
        for p in pool.prefix(30) { lines.append("\(p.sku)  \(Int(p.qty ?? 0)) 码") }
        if pool.count > 30 { lines.append("……还有 \(pool.count - 30) 款（条件收窄一点再看）") }
        return lines.joined(separator: "\n")
    }

    // MARK: - 比较

    static func comparison(_ msg: String, products: [Product]) -> String? {
        guard msg.contains("比") else { return nil }
        let cheaper = msg.contains("便宜") || msg.contains("低")
        let pricier = msg.contains("贵") || msg.contains("高")
        guard cheaper || pricier else { return nil }

        guard let code = extractCodes(msg).first,
              let base = resolve(code, in: products),
              let basePrice = base.price else { return nil }

        let prefix = prefixFilter(msg)
        let pool = products.filter { p in
            guard let v = p.price else { return false }
            if let pre = prefix, !p.sku.hasPrefix(pre) { return false }
            return cheaper ? v < basePrice : v > basePrice
        }.sorted { a, b in
            let x = a.price ?? 0, y = b.price ?? 0
            return cheaper ? x > y : x < y
        }

        guard !pool.isEmpty else {
            return "没有比 \(base.sku)（\(formatPrice(basePrice))）" + (cheaper ? "更便宜的款。" : "更贵的款。")
        }

        let prefixText = prefix.map { "\($0) 开头的" } ?? ""
        var lines = ["\(prefixText)比 \(base.sku)（\(formatPrice(basePrice))）" + (cheaper ? "便宜的有 \(pool.count) 款：" : "贵的有 \(pool.count) 款：")]
        for p in pool.prefix(30) { lines.append("\(p.sku)  \(formatPrice(p.price ?? 0))") }
        if pool.count > 30 { lines.append("……还有 \(pool.count - 30) 款") }
        return lines.joined(separator: "\n")
    }

    static func formatPrice(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }

    // MARK: - 价格区间 / 分页

    static func priceRange(_ msg: String) -> (Double, Double)? {
        if let single = singlePriceAround(msg) { return single }

        let hasPriceWord = msg.contains("价") || msg.contains("元") || msg.contains("块")
        let pattern = "(\\d{1,5}(?:\\.\\d+)?)\\s*(?:-|~|到|至|—)\\s*(\\d{1,5}(?:\\.\\d+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = msg as NSString
        guard let m = regex.firstMatch(in: msg, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 3 else { return nil }
        let a = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let b = Double(ns.substring(with: m.range(at: 2))) ?? 0
        guard a > 0, b > 0 else { return nil }
        if !hasPriceWord {
            if msg.contains("库存") || msg.contains("码") { return nil }
            if max(a, b) >= 1000 { return nil }
        }
        return (min(a, b), max(a, b))
    }

    static func singlePriceAround(_ msg: String) -> (Double, Double)? {
        guard msg.contains("元") || msg.contains("块") || msg.contains("价") else { return nil }
        let pattern = "(\\d{1,5}(?:\\.\\d+)?)\\s*(?:元|块|钱)?\\s*(?:左右|上下|附近|差不多|大约|约)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = msg as NSString
        guard let m = regex.firstMatch(in: msg, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1,
              let v = Double(ns.substring(with: m.range(at: 1))), v > 0 else { return nil }
        let delta = v < 20 ? 2.0 : max(2.0, (v * 0.15).rounded())
        return (max(0, v - delta), v + delta)
    }

    static func pricePage(_ turn: RuleTurn, products: [Product], size: Int = pageSize) -> (String?, RuleTurn?) {
        let low = min(turn.low, turn.high)
        let high = max(turn.low, turn.high)
        let all = products
            .filter { ($0.price ?? -1) >= low && ($0.price ?? -1) <= high }
            .sorted { $0.sku.localizedStandardCompare($1.sku) == .orderedAscending }

        guard !all.isEmpty else { return ("\(intText(low))–\(intText(high)) 元这批没有款。", nil) }

        let start = turn.shown
        guard start < all.count else {
            return ("没有了，\(intText(low))–\(intText(high)) 元这批一共 \(all.count) 款。", nil)
        }

        let page = Array(all.dropFirst(start).prefix(size))
        var next = turn
        next.shown = start + page.count

        var lines: [String] = []
        if start == 0 {
            lines.append("\(intText(low))–\(intText(high)) 元这批共 \(all.count) 款，先给前 \(page.count) 个：")
        } else {
            lines.append("接着给 \(page.count) 个（\(start + 1)–\(start + page.count)）：")
        }
        for p in page { lines.append("\(p.sku)  \(p.priceText ?? "")") }
        if next.shown >= all.count {
            lines.append("—— 全部列完了，共 \(all.count) 款")
        } else {
            lines.append("—— 说「还有别的吗」看下一批")
        }
        return (lines.joined(separator: "\n"), next)
    }

    static func isFollowUp(_ msg: String) -> Bool {
        let keys = ["还有别的", "还有吗", "还有没有", "继续", "再列", "下一批",
                    "下一页", "其他的", "换一批", "再来"]
        return keys.contains { msg.contains($0) }
    }

    static func followUpCount(_ msg: String) -> Int? {
        let pattern = "(\\d{1,3})\\s*(?:个|款|条)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = msg as NSString
        guard let m = regex.firstMatch(in: msg, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1,
              let n = Int(ns.substring(with: m.range(at: 1))), n > 0 else { return nil }
        return min(n, 100)
    }

    // MARK: - 编号区间

    static func codeRange(_ msg: String, products: [Product]) -> (from: String, to: String, skus: [Product])? {
        let pattern = "([A-Za-z]{0,4})(\\d{1,6})\\s*(?:-|~|到|至|—|至)\\s*([A-Za-z]{0,4})(\\d{1,6})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = msg as NSString
        guard let m = regex.firstMatch(in: msg, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 5 else { return nil }

        let preA = ns.substring(with: m.range(at: 1)).uppercased()
        let numA = Int(ns.substring(with: m.range(at: 2))) ?? 0
        let preB = ns.substring(with: m.range(at: 3)).uppercased()
        let numB = Int(ns.substring(with: m.range(at: 4))) ?? 0
        guard numA > 0, numB > 0 else { return nil }
        let low = min(numA, numB), high = max(numA, numB)
        guard high - low <= 500 else { return nil }

        let pre = preA.isEmpty ? preB : preA
        let matched = products.filter { p in
            let s = p.sku.uppercased()
            guard pre.isEmpty || s.hasPrefix(pre) else { return false }
            var digits = ""
            for ch in s.dropFirst(pre.count) {
                if ch.isNumber { digits.append(ch) } else { break }
            }
            guard let v = Int(digits) else { return false }
            return v >= low && v <= high
        }.sorted { $0.sku.localizedStandardCompare($1.sku) == .orderedAscending }

        return (from: "\(pre)\(low)", to: "\(pre)\(high)", skus: matched)
    }

    // MARK: - AI 数字校验

    /// 严格校验：回答里的每个数字、每个编号，都必须来自工具返回或用户原话
    static func strictCheck(answer: String, evidence: String, question: String) -> Bool {
        // 数字
        let allowedNums = Set(numbers(in: evidence)).union(numbers(in: question))
        let white: Set<String> = ["0.9144", "1.0936"]

        for n in numbers(in: answer) {
            if allowedNums.contains(n) || white.contains(n) { continue }
            if let v = Double(n),
               allowedNums.contains(where: { Double($0).map { abs($0 - v) < 0.001 } ?? false }) { continue }
            return false
        }

        // 编号
        let knownCodes = Set(extractCodes(evidence).map { $0.uppercased() })
        let askedCodes = Set(extractCodes(question).map { $0.uppercased() })
        for c in extractCodes(answer) {
            let u = c.uppercased()
            if knownCodes.contains(u) || askedCodes.contains(u) { continue }
            return false
        }
        return true
    }

    static func numbersOK(answer: String, evidence: String, extra: String) -> Bool {
        let tokens = numbers(in: answer)
        if tokens.isEmpty { return true }
        guard !evidence.isEmpty else { return false }

        var known = Set(numbers(in: evidence))
        known.formUnion(numbers(in: extra))

        for t in tokens {
            if known.contains(t) { continue }
            if let v = Double(t), known.contains(where: { Double($0).map { abs($0 - v) < 0.001 } ?? false }) {
                continue
            }
            return false
        }
        return true
    }

    static func numbers(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\d+(?:\\.\\d+)?") else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    static func intText(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }
}
