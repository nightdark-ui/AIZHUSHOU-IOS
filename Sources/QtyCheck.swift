import Foundation

/// 数量异常检查
///   ① 单个批次（某一项）超过上限 → 多半是两个数字粘在一起（97 128 → 97128）
///   ② 单个批次（某一项）小于下限 → 多半是漏写或写错了（80*8+16+80+80 后面孤零零一个 8）
///
/// 注意：`80*7` 是「7 包 × 每包 80」，两项都不违规，不报。
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
            return "单项 \(term) 小于下限，可能漏写或写错"
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

            var text = raw
            text = text.replacingOccurrences(of: "，", with: "+")
            text = text.replacingOccurrences(of: ",", with: "+")
            text = text.replacingOccurrences(of: "、", with: "+")
            text = text.replacingOccurrences(of: "；", with: "+")
            text = text.replacingOccurrences(of: ";", with: "+")
            text = text.replacingOccurrences(of: "＋", with: "+")
            text = text.replacingOccurrences(of: "×", with: "*")
            text = text.replacingOccurrences(of: "✕", with: "*")
            text = text.replacingOccurrences(of: "x", with: "*")
            text = text.replacingOccurrences(of: "X", with: "*")
            text = text.replacingOccurrences(of: " ", with: "")

            // 只看数字开头那一段（后面可能跟着「1小包没码数」这类说明）
            if let cut = text.firstIndex(where: { $0.isLetter || ($0.unicodeScalars.first.map { $0.value >= 0x4E00 } ?? false) }) {
                text = String(text[..<cut])
            }
            guard !text.isEmpty else { continue }

            var found: QtyIssue?

            for term in text.split(separator: "+", omittingEmptySubsequences: true) {
                let factors = term.split(separator: "*", omittingEmptySubsequences: true)
                guard !factors.isEmpty else { continue }

                var values: [Double] = []
                var ok = true
                for f in factors {
                    guard let v = Double(f) else { ok = false; break }
                    values.append(v)
                }
                guard ok, !values.isEmpty else { continue }

                // ① 乘号里的单个数字超上限（80*7 里的 80，不是 560）
                if let big = values.first(where: { $0 > limit }) {
                    found = QtyIssue(sku: p.sku, term: trimZero(big), value: big, kind: .tooBig)
                    break
                }

                // ② 一整项的总数低于下限（"8"、"32+2" 里的 2）
                var product: Double = 1
                for v in values { product *= v }
                if product > 0, product < minimum {
                    found = QtyIssue(sku: p.sku, term: trimZero(product), value: product, kind: .tooSmall)
                    break
                }
            }

            if let issue = found, !ignored.contains(issue.ignoreKey) {
                issues.append(issue)
            }
        }

        return issues.sorted { a, b in
            if a.kind != b.kind { return a.kind == .tooBig }
            return a.value > b.value
        }
    }

    /// 某个款有没有问题
    static func issue(for sku: String, in issues: [QtyIssue]) -> QtyIssue? {
        issues.first { $0.sku.uppercased() == sku.uppercased() }
    }

    /// 97128.0 → "97128"
    private static func trimZero(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }
}
