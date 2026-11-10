import Foundation

/// 上一轮的状态（用于「还有别的吗」）
struct RuleTurn {
    var kind = ""          // "price" / "choose"
    var low: Double = 0
    var high: Double = 0
    var shown: Int = 0
    var options: [String] = []   // 让用户点选时的候选编号
}

/// 本地规则引擎：编号直达、区间、价格区间、闲聊，毫秒级
enum Rules {

    static let pageSize = 30

    /// 返回 (回答, 下一轮的上下文)；回答为 nil 表示规则答不了
    static func answer(_ text: String,
                       products: [Product],
                       restock: [RestockItem],
                       threshold: Double,
                       turn: RuleTurn?) -> (text: String?, turn: RuleTurn?) {

        let msg = normalize(text)
        guard !msg.isEmpty else { return (nil, turn) }
        let wantMeters = wantsMeters(msg)

        // 0. 追问：还有别的吗 / 继续
        if let t = turn, t.kind == "price", isFollowUp(msg) {
            return pricePage(t, products: products, size: followUpCount(msg) ?? pageSize)
        }

        // 1. 闲聊
        if let chat = chitchat(msg, productCount: products.count) {
            return (chat, nil)
        }

        // 1b. 离题（天气、新闻、写代码…）
        if let off = offtopic(msg) {
            return (off, nil)
        }

        // 1b2. 总览/统计
        if let overview = overviewReply(msg, products: products, restock: restock) {
            return (overview, nil)
        }

        // 1c. 比某个编号贵 / 便宜
        if let cmp = comparison(msg, products: products) {
            return (cmp, nil)
        }

        // 2. 价格区间（价格10到20的款）
        if let range = priceRange(msg) {
            let t = RuleTurn(kind: "price", low: range.0, high: range.1, shown: 0)
            return pricePage(t, products: products)
        }

        // 3. 编号区间（2001-2010 库存），支持加价格/库存条件
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
                pool = pool.filter { ($0.qty ?? -1) <= qmax && $0.qty != nil }
                condText.append("库存 ≤ \(Int(qmax))")
            }

            if pool.isEmpty {
                return ("\(cr.from)–\(cr.to) 里没有符合条件的款。", nil)
            }
            let extra = condText.isEmpty ? "" : "（\(condText.joined(separator: "、"))）"
            var lines = ["\(cr.from)–\(cr.to) 共 \(cr.skus.count) 个，符合条件 \(pool.count) 个\(extra)："]
            for p in pool.prefix(40) {
                lines.append("· \(p.sku)  " + qtyBrief(p))
            }
            if pool.count > 40 { lines.append("……还有 \(pool.count - 40) 个") }
            return (lines.joined(separator: "\n"), nil)
        }

        // 4. 补货
        if msg.contains("补货") || msg.contains("要补") || msg.contains("缺货") {
            if let code = extractCodes(msg).first, let p = find(code, in: products) {
                return (restockAdvice(p, threshold: threshold), nil)
            }
            if restock.isEmpty {
                return ("现在没有需要补货的款 👍", nil)
            }
            var lines = ["需要补货的有 \(restock.count) 个款："]
            for item in restock.prefix(10) { lines.append(detailLine(item)) }
            if restock.count > 10 { lines.append("……还有 \(restock.count - 10) 个") }
            return (lines.joined(separator: "\n"), nil)
        }

        // 5. 够不够（2002 有没有300）
        if let need = thresholdNumber(msg) {
            if let p = findAny(msg, in: products) {
                return (thresholdAnswer(p, need: need) + metersSuffix(p, want: wantMeters), nil)
            }
            if extractCodes(msg).isEmpty {
                return ("要问哪个编号？比如「2002 有没有\(Int(need))」或「SL1004 够\(Int(need))吗」。", nil)
            }
        }

        let codes = extractCodes(msg)
        guard !codes.isEmpty else { return (nil, nil) }

        // 6. 多个编号
        if codes.count >= 2 {
            var lines: [String] = []
            var missing: [String] = []
            for code in codes {
                if let p = find(code, in: products) {
                    if !lines.isEmpty { lines.append("") }
                    let price = p.priceText?.isEmpty == false ? p.priceText! : "未填"
                    lines.append(p.sku)
                    lines.append("价格 \(price)")
                    if let q = p.qty {
                        let raw = (p.qtyText ?? "").trimmingCharacters(in: .whitespaces)
                        if !raw.isEmpty, Double(raw) == nil {
                            lines.append("库存 \(Int(q)) 码")
                            lines.append("（\(raw)）")
                        } else {
                            lines.append("库存 \(Int(q)) 码")
                        }
                    } else if let t = p.qtyText, !t.isEmpty {
                        lines.append("数量算不出来（表格写「\(t)」）")
                    } else {
                        lines.append("数量未填")
                    }
                } else {
                    missing.append(code)
                }
            }
            if lines.isEmpty { return (nil, nil) }
            var out = lines.joined(separator: "\n")
            if !missing.isEmpty { out += "\n另外 \(missing.joined(separator: "、")) 没找到。" }
            return (out, nil)
        }

        // 7. 单个编号
        let code = codes[0]

        // 7a00. 只有前缀匹配到多个（PDX1008 → PDX1008-1 / PDX1008-2）
        let prefixed = products.filter { $0.sku.uppercased().hasPrefix(code.uppercased()) }
        if prefixed.count > 1, !prefixed.contains(where: { $0.sku.uppercased() == code.uppercased() }) {
            var lines = ["「\(code)」对应 \(prefixed.count) 个编号，点下面选一个："]
            for v in prefixed.prefix(8) { lines.append("· \(v.sku)  \(stockText(v))") }
            var turn = RuleTurn(kind: "choose")
            turn.options = prefixed.prefix(8).map { $0.sku }
            return (lines.joined(separator: "\n"), turn)
        }

        // 7a0. 编号 + 说明：9005 32梭 → 9005(32梭）
        if let exact = resolveWithSuffix(code: code, message: msg, products: products) {
            return (stockText(exact), nil)
        }

        // 7a. 有多种写法：2002 / 2002-1
        let variants = variantList(code, in: products)
        let asksSomething = msg.contains("价格") || msg.contains("多少钱") || msg.contains("价")
            || msg.contains("库存") || msg.contains("还有") || msg.contains("剩")
            || msg.contains("米") || msg.contains("图片") || msg.contains("照片")
        if variants.count > 1 && !asksSomething {
            var turn = RuleTurn(kind: "choose")
            turn.options = variants.prefix(8).map { $0.sku }
            return ("「\(code)」有 \(variants.count) 种写法，点下面选一个：", turn)
        }

        guard let p = find(code, in: products) else {
            let near = suggest(code, in: products)
            if !near.isEmpty {
                var lines = ["没找到「\(code)」。是不是这些："]
                for n in near { lines.append("· \(n.sku)  \(stockText(n))") }
                lines.append("（直接发编号就行）")
                return (lines.joined(separator: "\n"), nil)
            }
            return ("没找到「\(code)」。可以说完整编号（比如 2002），或者问「2001-2010 库存」。", nil)
        }

        // 要看图
        if msg.contains("图片") || msg.contains("照片") || msg.contains("长什么样") {
            return ("\(p.sku) 的图片：", nil)
        }

        let asksPrice = msg.contains("价格") || msg.contains("多少钱") || msg.contains("价")
        let asksStock = msg.contains("库存") || msg.contains("还剩") || msg.contains("还有")
            || msg.contains("够") || msg.contains("码") || msg.contains("米")
        let price = p.priceText?.isEmpty == false ? p.priceText! : "未填"

        if asksPrice && asksStock {
            var lines = ["\(p.sku)", "价格 \(price)"]
            if let q = p.qty {
                lines.append("库存 \(Int(q)) 码")
                let raw = (p.qtyText ?? "").trimmingCharacters(in: .whitespaces)
                if !raw.isEmpty, Double(raw) == nil {
                    lines.append("（\(raw)）")
                }
            } else {
                lines.append(stockText(p))
            }
            return (lines.joined(separator: "\n") + metersSuffix(p, want: wantMeters), nil)
        }
        if asksPrice {
            return ("\(p.sku)  价格 \(price)", nil)
        }
        return (stockText(p) + metersSuffix(p, want: wantMeters), nil)
    }

    /// 「比2002贵的花」「比2002便宜的」
    static func comparison(_ msg: String, products: [Product]) -> String? {
        guard msg.contains("比") else { return nil }
        let cheaper = msg.contains("便宜") || msg.contains("低")
        let pricier = msg.contains("贵") || msg.contains("高")
        guard cheaper || pricier else { return nil }

        guard let code = extractCodes(msg).first,
              let base = find(code, in: products),
              let basePrice = base.price else { return nil }

        let pool = products.filter { p in
            guard let v = p.price else { return false }
            return cheaper ? v < basePrice : v > basePrice
        }.sorted { a, b in
            let x = a.price ?? 0, y = b.price ?? 0
            return cheaper ? x > y : x < y
        }

        guard !pool.isEmpty else {
            return "没有比 \(base.sku)（\(formatPrice(basePrice))）" + (cheaper ? "更便宜的款。" : "更贵的款。")
        }

        var lines = ["比 \(base.sku)（\(formatPrice(basePrice))）" + (cheaper ? "便宜的有 \(pool.count) 款：" : "贵的有 \(pool.count) 款：")]
        for p in pool.prefix(30) {
            lines.append("\(p.sku)  \(formatPrice(p.price ?? 0))")
        }
        if pool.count > 30 { lines.append("……还有 \(pool.count - 30) 款") }
        return lines.joined(separator: "\n")
    }

    static func formatPrice(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }

    /// 总览统计
    static func overviewReply(_ msg: String, products: [Product], restock: [RestockItem]) -> String? {
        let keys = ["总览", "整体", "一共", "总共", "多少种", "多少个款", "统计", "销量", "卖得", "情况"]
        guard keys.contains(where: { msg.contains($0) }) else { return nil }

        let total = products.count
        let withQty = products.filter { $0.qty != nil }.count
        let zero = products.filter { ($0.qty ?? 1) <= 0 && $0.qty != nil }.count
        let withPrice = products.filter { $0.price != nil }.count
        let outToday = restock.count

        var lines: [String] = []
        lines.append("一共 \(total) 个款，其中 \(withQty) 个有数量、\(withPrice) 个有价格。")
        lines.append("没货的 \(zero) 个。")
        if outToday > 0 {
            lines.append("今天需要补的 \(outToday) 个。")
        } else {
            lines.append("今天没有需要补的。")
        }
        return lines.joined(separator: "\n")
    }

    /// 「库存 500 以上」「500 码以上」
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

    /// 「库存 500 以下」「500 码以内」
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

    // MARK: - 分页（价格区间）

    static func pricePage(_ turn: RuleTurn, products: [Product], size: Int = pageSize) -> (String?, RuleTurn?) {
        let low = min(turn.low, turn.high)
        let high = max(turn.low, turn.high)
        let all = products
            .filter { ($0.price ?? -1) >= low && ($0.price ?? -1) <= high }
            .sorted { $0.sku.localizedStandardCompare($1.sku) == .orderedAscending }

        guard !all.isEmpty else {
            return ("\(intText(low))–\(intText(high)) 元这批没有款。", nil)
        }

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
        for p in page {
            lines.append("\(p.sku)  \(p.priceText ?? "")")
        }
        if next.shown >= all.count {
            lines.append("—— 全部列完了，共 \(all.count) 款")
        } else {
            lines.append("—— 说「还有别的吗」看下一批")
        }
        return (lines.joined(separator: "\n"), next)
    }

    // MARK: - 解析

    static func isFollowUp(_ msg: String) -> Bool {
        let keys = ["还有别的", "还有吗", "还有没有", "继续", "再列", "下一批",
                    "下一页", "其他的", "换一批", "再来"]
        return keys.contains { msg.contains($0) }
    }

    /// 「换一批 20 个」里的数量
    static func followUpCount(_ msg: String) -> Int? {
        let pattern = "(\\d{1,3})\\s*(?:个|款|条)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = msg as NSString
        guard let m = regex.firstMatch(in: msg, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1,
              let n = Int(ns.substring(with: m.range(at: 1))), n > 0 else { return nil }
        return min(n, 100)
    }

    /// 价格区间：价格10到20 / 10-20元的 / 15到30块 / 10元左右
    static func priceRange(_ msg: String) -> (Double, Double)? {
        // 单个数字 + 左右/上下
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

        // 没写"价/元/块"时，只有数字很大（≥1000）才更像编号区间，交给编号区间处理
        if !hasPriceWord {
            if msg.contains("库存") || msg.contains("码") { return nil }
            if max(a, b) >= 1000 { return nil }
        }
        return (min(a, b), max(a, b))
    }

    /// 「10元左右」「15块上下」
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

    /// 编号区间：2001-2010 / SL100-120
    static func codeRange(_ msg: String, products: [Product]) -> (from: String, to: String, skus: [Product])? {
        let pattern = "([A-Za-z]{0,4})(\\d{1,6})\\s*(?:-|~|到|至|—)\\s*([A-Za-z]{0,4})(\\d{1,6})"
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
            // 取编号里的第一段数字
            var digits = ""
            for ch in s.dropFirst(pre.count) {
                if ch.isNumber { digits.append(ch) } else { break }
            }
            guard let v = Int(digits) else { return false }
            return v >= low && v <= high
        }.sorted { $0.sku.localizedStandardCompare($1.sku) == .orderedAscending }

        return (from: "\(pre)\(low)", to: "\(pre)\(high)", skus: matched)
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

    /// 用户是在问「米」吗（同时说了码就按码）
    static func wantsMeters(_ msg: String) -> Bool {
        msg.contains("米") && !msg.contains("码")
    }

    /// 码 → 米的补充说明
    static func metersSuffix(_ p: Product, want: Bool) -> String {
        guard want, let q = p.qty, q > 0 else { return "" }
        return "\n" + metersText(q)
    }

    static func metersText(_ yards: Double) -> String {
        let meters = yards * 0.9144
        let text = abs(meters - meters.rounded()) < 0.5
            ? String(format: "%.0f", meters)
            : String(format: "%.1f", meters)
        return "（\(Int(yards)) 码 ≈ \(text) 米，1 码 = 0.9144 米）"
    }

    /// 有算式就带明细：96+103+95+117+166 = 577
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

    // MARK: - 离题 / 相似编号 / 说明匹配

    static func offtopic(_ msg: String) -> String? {
        let keys = ["天气", "新闻", "股票", "汇率", "比特币", "笑话", "唱歌", "讲故事",
                    "写代码", "编程", "翻译", "作文", "电影", "歌曲", "游戏", "几点了"]
        guard keys.contains(where: { msg.contains($0) }) else { return nil }
        // 句子里有编号/库存/价格/补货字样就不算离题
        let business = ["库存", "价格", "多少钱", "补货", "码", "款号"]
        if business.contains(where: { msg.contains($0) }) { return nil }
        return "这个我帮不上忙，我只会查库存、查价格、看补货。"
    }

    /// 编号 + 说明：9005 32梭 → 9005(32梭）
    static func resolveWithSuffix(code: String, message: String, products: [Product]) -> Product? {
        let variants = variantList(code, in: products)
        guard variants.count > 1 else { return nil }

        let rest = message.replacingOccurrences(of: code, with: "")
        let normalized = rest.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
        guard !normalized.isEmpty else { return nil }

        var hits: [Product] = []
        for v in variants {
            let suffix = v.sku.uppercased()
                .replacingOccurrences(of: code.uppercased(), with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: "）", with: "")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
            guard !suffix.isEmpty else { continue }
            if normalized.contains(suffix) { hits.append(v) }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// 打错字/编号不存在时，给最像的几个
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

    /// AI 回答里的每个数字都必须在证据里，否则算编造
    static func numbersOK(answer: String, evidence: String, extra: String) -> Bool {
        let tokens = numbers(in: answer)
        if tokens.isEmpty { return true }
        guard !evidence.isEmpty else { return false }

        var known = Set(numbers(in: evidence))
        known.formUnion(numbers(in: extra))

        for t in tokens {
            if known.contains(t) { continue }
            // 允许 577 vs 577.0 这种
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

    // MARK: - 闲聊

    static func chitchat(_ msg: String, productCount: Int) -> String? {
        let greetings = ["你好", "您好", "在吗", "在不在", "hi", "hello", "哈喽", "早上好", "晚上好", "下午好"]
        let thanks = ["谢谢", "多谢", "感谢", "辛苦"]
        let who = ["你是谁", "你叫什么", "你能干什么", "你会什么", "怎么用"]

        if who.contains(where: { msg.contains($0) }) {
            return "我是你的库存小助手。可以这样问我：\n· 2002 库存\n· 2002 多少钱\n· 2002 有没有300\n· 2001-2010 库存\n· 价格10到20的款\n· 有什么要补货的"
        }
        if thanks.contains(where: { msg.contains($0) }) {
            return "不客气，主人。"
        }
        if greetings.contains(where: { msg.lowercased() == $0 || msg.hasPrefix($0) }) {
            if productCount == 0 {
                return "主人好！我还没有数据，先去「设置」同步一次吧。"
            }
            return "主人好！我是 AI 小助手，可以帮主人查库存、查价格、看补货。"
        }
        return nil
    }

    // MARK: - 文本处理

    static func normalize(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "，", with: ",")
        s = s.replacingOccurrences(of: "？", with: "?")
        s = s.replacingOccurrences(of: "！", with: "!")
        return s
    }

    static func extractCodes(_ text: String) -> [String] {
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
            for m in regex.matches(in: work, range: NSRange(location: 0, length: ns.length)) {
                var s = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
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
        return Double(ns.substring(with: m.range(at: 1)))
    }

    static func find(_ code: String, in products: [Product]) -> Product? {
        let target = code.uppercased()
        if let exact = products.first(where: { $0.sku.uppercased() == target }) { return exact }
        if let prefix = products.first(where: { $0.sku.uppercased().hasPrefix(target) }) {
            return prefix
        }
        // 括号里的片段：「A78」→ SL5006(A78)
        if target.count >= 2 {
            return products.first { p in
                let s = p.sku.uppercased()
                return s.contains("(\(target)") || s.contains("（\(target)") || s.contains("\(target))")
            }
        }
        return nil
    }

    /// 同一编号的不同写法：2002 / 2002-1 / 2002（32梭）
    static func variantList(_ code: String, in products: [Product]) -> [Product] {
        let t = code.uppercased()
        return products.filter { p in
            let s = p.sku.uppercased()
            if s == t { return true }
            if s.hasPrefix(t + "-") || s.hasPrefix(t + "_") { return true }
            if s.hasPrefix(t + "(") || s.hasPrefix(t + "（") { return true }
            return false
        }
    }

    static func findAny(_ text: String, in products: [Product]) -> Product? {
        for c in extractCodes(text) {
            if let p = find(c, in: products) { return p }
        }
        let head = text.split(whereSeparator: { "有没有够到超过大于至少码吗么呢? ".contains($0) }).first
        if let h = head {
            let s = String(h).trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, let p = find(s, in: products) { return p }
        }
        return nil
    }

    static func intText(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }
}
