import Foundation

/// 数量异常检查：某一条（单个包装/一批）数量超过上限，多半是两个数字粘在一起了。
///
/// 例：表格里写「97 128」→ WPS 存成 97128 → 单项 = 97128 > 500 → 报警。
struct QtyIssue: Identifiable, Hashable {
    var sku: String
    /// 触发问题的那一段原文，比如 "97128"
    var term: String
    /// 这一段算出来的数
    var value: Double

    var id: String { sku }

    /// 给用户看的说明
    var hint: String {
        if term.filter({ $0.isNumber }).count >= 4 {
            return "单项 \(term) 超过上限，可能是两个数字粘在一起"
        }
        return "单项 \(term) 超过上限"
    }
}

enum QtyCheck {

    /// 单个批次的上限（店主确认：单条不会超过 500）
    static let singleLimit: Double = 500

    /// 从数量文字里拆出每一项，找出超过上限的
    static func analyze(_ products: [Product], limit: Double = singleLimit) -> [QtyIssue] {
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

            // 只看数字开头的那一段（后面可能跟着「1小包没码数」这类说明）
            if let cut = text.firstIndex(where: { $0.isLetter || ($0.unicodeScalars.first.map { $0.value >= 0x4E00 } ?? false) }) {
                text = String(text[..<cut])
            }
            guard !text.isEmpty else { continue }

            for term in text.split(separator: "+", omittingEmptySubsequences: true) {
                let factors = term.split(separator: "*", omittingEmptySubsequences: true)
                guard !factors.isEmpty else { continue }

                // 只看单个数字：80*7 是「7 包、每包 80」，不是 560
                var hit: Double?
                for f in factors {
                    guard let v = Double(f) else { continue }
                    if v > limit {
                        hit = v
                        break
                    }
                }
                guard let value = hit else { continue }

                issues.append(QtyIssue(sku: p.sku, term: Self.trimZero(value), value: value))
                break   // 一个款只报一次
            }
        }

        return issues.sorted { $0.value > $1.value }
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
