import Foundation

/// 数量异常检查
///   ① 单个批次（某一项）超过上限 → 多半是两个数字粘在一起（97 128 → 97128）
///   ② 单个批次（某一项）低于下限 → 多半是漏写或只剩零头
///
/// 关键规则：
///   · `80*7` 是「7 包 × 每包 80」，两个数字都不违规，不报
///   · 含中文/字母的那一段当说明处理（"1小包没码数" 里的 1 不算数字）
struct QtyIssue: Identifiable, Hashable {

    enum Kind: String {
        case tooBig
        case tooSmall
    }

    var sku: String
    /// 触发问题的那一段原文，比如 "97128"
    var term: String
    /// 这一段算出来的数
    var value: Double
    var kind: Kind

    var id: String { sku }

    /// 忽略用的指纹：款号 + 类型 + 数值（数值变了会重新提醒）
    var ignoreKey: String {
        "\(sku.uppercased())|\(kind.rawValue)|\(Int(value))"
    }

    var hint: String {
        switch kind {
        case .tooBig:
            if term.filter({ $0.isNumber }).count >= 4 {
                return "单项 \(term) 超过上限，可能是两个数字粘在一起"
            }
            return "单项 \(term) 超过上限"
        case .tooSmall:
            return "单项 \(term) 低于下限，可能漏写或只剩零头"
        }
    }
}

enum QtyCheck {

    /// 单个批次的上限（店主确认：单条不会超过 500）
    static let singleLimit: Double = 500
    /// 单个批次的下限
    static let singleMin: Double = 10

    /// 从数量文字里拆出每一项，找出超上限 / 低于下限的
    static func analyze(_ products: [Product],
                        limit: Double = singleLimit,
                        minimum: Double = singleMin,
                        ignored: Set<String> = []) -> [QtyIssue] {
        var issues: [QtyIssue] = []

        for p in products {
            guard let raw = p.qtyText?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
            guard let issue = inspect(sku: p.sku, text: raw, limit: limit, minimum: minimum) else { continue }
            if ignored.contains(issue.ignoreKey) { continue }
            issues.append(issue)
        }

        return issues.sorted { a, b in
            if a.kind != b.kind { return a.kind == .tooBig }
            return a.value > b.value
        }
    }

    /// 检查单个款的文字
    static func inspect(sku: String, text: String,
                        limit: Double = singleLimit,
                        minimum: Double = singleMin) -> QtyIssue? {
        // 先按分隔符切段，再逐段判断：
        // 含中文/字母的段（"1小包没码数"、"8m"）整段当说明跳过
        var segments = text
        segments = segments.replacingOccurrences(of: "＋", with: "+")
        segments = segments.replacingOccurrences(of: "；", with: "+")
        segments = segments.replacingOccurrences(of: ";", with: "+")

        let pieces = segments.split(whereSeparator: { ch in
            ch == "+" || ch == "，" || ch == "," || ch == "、" || ch == "＋"
        })

        for piece in pieces {
            let seg = piece.trimmingCharacters(in: .whitespaces)
            guard !seg.isEmpty else { continue }

            // 有中文或字母 → 说明文字，跳过
            if seg.contains(where: { $0.isLetter || isCJK($0) }) { continue }

            let cleaned = seg
                .replacingOccurrences(of: "×", with: "*")
                .replacingOccurrences(of: "✕", with: "*")
                .replacingOccurrences(of: "x", with: "*")
                .replacingOccurrences(of: "X", with: "*")
                .replacingOccurrences(of: " ", with: "")

            let factors = cleaned.split(separator: "*", omittingEmptySubsequences: true)
            guard !factors.isEmpty else { continue }

            var values: [Double] = []
            var ok = true
            for f in factors {
                guard let v = Double(f) else { ok = false; break }
                values.append(v)
            }
            guard ok, !values.isEmpty else { continue }

            // ① 乘号里单个数字超上限（80*7 里的 80，不是 560）
            if let big = values.first(where: { $0 > limit }) {
                return QtyIssue(sku: sku, term: trimZero(big), value: big, kind: .tooBig)
            }

            // ② 整段总数低于下限
            var product: Double = 1
            for v in values { product *= v }
            if product > 0, product < minimum {
                return QtyIssue(sku: sku, term: trimZero(product), value: product, kind: .tooSmall)
            }
        }

        return nil
    }

    /// 某个款有没有问题
    static func issue(for sku: String, in issues: [QtyIssue]) -> QtyIssue? {
        issues.first { $0.sku.uppercased() == sku.uppercased() }
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first else { return false }
        return s.value >= 0x4E00 && s.value <= 0x9FA5
    }

    /// 97128.0 → "97128"
    private static func trimZero(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }
}
