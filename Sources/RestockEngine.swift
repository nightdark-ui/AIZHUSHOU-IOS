import Foundation

/// 补货计算（和电脑版规则一致）
///
/// 触发条件：
///   ① 数量比"上一次快照"少了
///   ② 当前数量低于提醒线（默认 300，单款可设）
enum RestockEngine {

    static func build(products: [Product],
                      day: String,
                      threshold: Double,
                      acks: Set<String>,
                      dayBaseline: [String: Double]? = nil) -> [RestockItem] {

        // 优先用「今天之前最近的快照」；没有历史时退回「今日基准」（当天第一次的值）
        let prev: (date: String, values: [String: Double])
        if let p = Storage.previousSnapshot(before: day) {
            prev = p
        } else if let base = dayBaseline, !base.isEmpty {
            prev = (day, base)
        } else {
            return []
        }
        var out: [RestockItem] = []

        for p in products {
            guard let qty = p.qty else { continue }          // 有文字但算不出的先跳过
            let limit = p.minQty ?? threshold
            if qty >= limit { continue }

            // 上次快照里没有这个款 → 现在没货（0）的也要报「没货了」
            guard let prevQty = prev.values[p.sku] else {
                if qty <= 0 {
                    let key = Storage.ackKey(sku: p.sku, prevDate: prev.date, qty: qty)
                    if !acks.contains(key) {
                        out.append(RestockItem(sku: p.sku, level: "danger", qty: qty,
                                               qtyText: (p.qtyText ?? ""),
                                               prevQty: 0, prevDate: prev.date,
                                               change: 0,
                                               reason: "现在没货（上次快照里没有这个款）",
                                               openedDay: day))
                    }
                }
                continue
            }

            let change = qty - prevQty
            if change >= 0 { continue }                       // 没减少就不提醒

            let key = Storage.ackKey(sku: p.sku, prevDate: prev.date, qty: qty)
            if acks.contains(key) { continue }                // 已经确认过

            let level = qty <= 0 ? "danger" : "warn"
            let raw = (p.qtyText ?? "").trimmingCharacters(in: .whitespaces)
            out.append(RestockItem(
                sku: p.sku,
                level: level,
                qty: qty,
                qtyText: raw,
                prevQty: prevQty,
                prevDate: prev.date,
                change: change,
                reason: "原 \(Int(prevQty)) 变成今天 \(Int(qty))（\(Int(change))）；当前 \(Int(qty))",
                openedDay: day
            ))
        }

        return out.sorted { lhs, rhs in
            if lhs.level != rhs.level { return lhs.level == "danger" }
            return abs(lhs.change) > abs(rhs.change)
        }
    }
}
