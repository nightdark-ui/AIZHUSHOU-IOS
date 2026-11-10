import Foundation

/// 给 AI 用的查询工具：AI 自己决定查什么，我们本地执行
enum AITools {

    /// 工具定义（OpenAI / DeepSeek 兼容格式）
    static var definitions: [[String: Any]] {
        [
            [
                "type": "function",
                "function": [
                    "name": "find_product",
                    "description": "按编号精确查一个款的价格和库存。编号可以是 2002、2053密、SL1004、9005(32梭) 等。",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "code": ["type": "string", "description": "款号（编号）"]
                        ],
                        "required": ["code"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "list_products",
                    "description": "按条件筛选款。用于「超过300米的」「2开头的」「10元左右的」「库存500以上的」这类问题。返回最多 limit 个款。",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "prefix": ["type": "string", "description": "编号开头，比如 2 表示 2 开头的款"],
                            "price_min": ["type": "number", "description": "最低单价"],
                            "price_max": ["type": "number", "description": "最高单价"],
                            "qty_min": ["type": "number", "description": "最低库存（单位：码）"],
                            "qty_max": ["type": "number", "description": "最高库存（单位：码）"],
                            "sort": ["type": "string", "enum": ["qty_desc", "qty_asc", "price_asc", "price_desc", "sku"],
                                     "description": "排序方式"],
                            "limit": ["type": "integer", "description": "返回条数，默认 30，最多 50"]
                        ],
                        "required": []
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "code_range",
                    "description": "查一个编号区间，比如 2001-2010。",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "from": ["type": "string", "description": "起始编号，如 2001"],
                            "to": ["type": "string", "description": "结束编号，如 2010"]
                        ],
                        "required": ["from", "to"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "restock_list",
                    "description": "查当前需要补货的款（库存比上次少、且低于提醒线的）。",
                    "parameters": [
                        "type": "object",
                        "properties": [:],
                        "required": []
                    ]
                ]
            ]
        ]
    }

    /// 执行工具，返回给 AI 的文本（同时作为数字校验的证据）
    static func run(name: String,
                    arguments: [String: Any],
                    products: [Product],
                    restock: [RestockItem]) -> String {

        switch name {
        case "find_product":
            let code = (arguments["code"] as? String) ?? ""
            guard !code.isEmpty else { return "缺少 code" }
            if let p = Rules.resolve(code, in: products) {
                return line(p)
            }
            let near = Rules.suggest(code, in: products)
            if near.isEmpty { return "没找到 \(code)" }
            return "没找到 \(code)，相近的有：\n" + near.map { line($0) }.joined(separator: "\n")

        case "list_products":
            let prefix = (arguments["prefix"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let priceMin = (arguments["price_min"] as? NSNumber)?.doubleValue
            let priceMax = (arguments["price_max"] as? NSNumber)?.doubleValue
            let qtyMin = (arguments["qty_min"] as? NSNumber)?.doubleValue
            let qtyMax = (arguments["qty_max"] as? NSNumber)?.doubleValue
            let sort = (arguments["sort"] as? String) ?? "qty_desc"
            let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 30, 1), 50)

            var pool = products.filter { p in
                if !prefix.isEmpty && !p.sku.hasPrefix(prefix) { return false }
                if let lo = priceMin { guard let v = p.price, v >= lo else { return false } }
                if let hi = priceMax { guard let v = p.price, v <= hi else { return false } }
                if qtyMin != nil || qtyMax != nil {
                    guard let q = p.qty else { return false }
                    if let lo = qtyMin, q < lo { return false }
                    if let hi = qtyMax, q > hi { return false }
                }
                return true
            }

            switch sort {
            case "qty_asc": pool.sort { ($0.qty ?? 0) < ($1.qty ?? 0) }
            case "price_asc": pool.sort { ($0.price ?? 0) < ($1.price ?? 0) }
            case "price_desc": pool.sort { ($0.price ?? 0) > ($1.price ?? 0) }
            case "sku": pool.sort { $0.sku.localizedStandardCompare($1.sku) == .orderedAscending }
            default: pool.sort { ($0.qty ?? 0) > ($1.qty ?? 0) }
            }

            guard !pool.isEmpty else { return "没有符合条件的款" }
            var out = "共 \(pool.count) 个符合条件的款，返回前 \(min(limit, pool.count)) 个：\n"
            out += pool.prefix(limit).map { line($0) }.joined(separator: "\n")
            return out

        case "code_range":
            let from = (arguments["from"] as? String) ?? ""
            let to = (arguments["to"] as? String) ?? ""
            let pattern = "([A-Za-z]{0,4})(\\d{1,6})"
            func split(_ s: String) -> (String, Int)? {
                guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$") else { return nil }
                let ns = s as NSString
                guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
                      m.numberOfRanges > 2 else { return nil }
                return (ns.substring(with: m.range(at: 1)).uppercased(),
                        Int(ns.substring(with: m.range(at: 2))) ?? 0)
            }
            guard let a = split(from), let b = split(to) else { return "区间写法不对" }
            let lo = min(a.1, b.1), hi = max(a.1, b.1)
            let pre = a.0.isEmpty ? b.0 : a.0
            let pool = products.filter { p in
                let s = p.sku.uppercased()
                guard pre.isEmpty || s.hasPrefix(pre) else { return false }
                var digits = ""
                for ch in s.dropFirst(pre.count) {
                    if ch.isNumber { digits.append(ch) } else { break }
                }
                guard let v = Int(digits) else { return false }
                return v >= lo && v <= hi
            }.sorted { $0.sku.localizedStandardCompare($1.sku) == .orderedAscending }
            guard !pool.isEmpty else { return "区间内没有款" }
            var out = "\(from)–\(to) 共 \(pool.count) 个：\n"
            out += pool.prefix(40).map { line($0) }.joined(separator: "\n")
            return out

        case "restock_list":
            guard !restock.isEmpty else { return "当前没有需要补货的款" }
            var out = "需要补货的 \(restock.count) 个：\n"
            out += restock.prefix(40).map { item in
                "\(item.sku) 原来 \(Int(item.prevQty ?? 0)) 变成 \(Int(item.qty ?? 0))（\(Int(item.change))）"
            }.joined(separator: "\n")
            return out

        default:
            return "未知工具 \(name)"
        }
    }

    static func line(_ p: Product) -> String {
        let price = p.priceText?.isEmpty == false ? p.priceText! : "未填"
        let qty: String
        if let q = p.qty {
            let raw = (p.qtyText ?? "").trimmingCharacters(in: .whitespaces)
            qty = raw.isEmpty || Double(raw) != nil ? "\(Int(q))" : "\(raw) = \(Int(q))"
        } else if let t = p.qtyText, !t.isEmpty {
            qty = "算不出（表格写「\(t)」）"
        } else {
            qty = "未填"
        }
        return "\(p.sku) | 价格 \(price) | 库存 \(qty) 码"
    }
}
