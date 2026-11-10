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
                      acks: Set<String>) -> [RestockItem] {

        guard let prev = Storage.previousSnapshot(before: day) else { return [] }
        var out: [RestockItem] = []

        for p in products {
            guard let qty = p.qty else { continue }          // 算不出数字的这版先跳过
            let limit = p.minQty ?? threshold
            if qty >= limit { continue }
            guard let prevQty = prev.values[p.sku] else { continue }

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
                reason: "原来 \(Int(prevQty)) 码（\(prev.date)）→ 现在 \(Int(qty)) 码，少了 \(Int(abs(change)))；低于提醒线 \(Int(limit))",
                openedDay: day
            ))
        }

        return out.sorted { lhs, rhs in
            if lhs.level != rhs.level { return lhs.level == "danger" }
            return abs(lhs.change) > abs(rhs.change)
        }
    }
}
