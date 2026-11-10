import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {

    @Published var settings: AppSettings = AppSettings()
    @Published var products: [Product] = []
    @Published var syncing = false
    @Published var statusText = "还没同步"
    @Published var lastSync: Date?

    private let settingsKey = "aizhushou.settings.v1"

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var productsURL: URL {
        documents.appendingPathComponent("products.json")
    }

    init() {
        loadSettings()
        loadProducts()
        if !products.isEmpty {
            statusText = "本地有 \(products.count) 个款（\(lastSyncText)）"
        }
    }

    var lastSyncText: String {
        guard let d = lastSync else { return "未同步" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: - 设置

    func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return }
        settings = s
    }

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
        statusText = "设置已保存"
    }

    // MARK: - 本地库存

    func loadProducts() {
        guard let data = try? Data(contentsOf: productsURL),
              let list = try? JSONDecoder().decode([Product].self, from: data) else { return }
        products = list
    }

    func saveProducts() {
        if let data = try? JSONEncoder().encode(products) {
            try? data.write(to: productsURL, options: .atomic)
        }
    }

    // MARK: - 同步

    func sync() async {
        guard !syncing else { return }
        syncing = true
        statusText = "正在同步…"
        defer { syncing = false }

        do {
            // 库存表：让脚本把「数量」原文传回来（sum=0 不预先求和）
            statusText = "正在拉库存表…"
            let stockRows = try await WPSClient.pullAll(
                token: settings.inventoryToken,
                fileId: settings.inventoryFileId,
                scriptId: settings.inventoryScriptId,
                argv: ["mode": "codes", "field": "库存", "sum": "0",
                       "gap": "4", "dropEmpty": "1", "money": "0"]
            )

            // 价格表：没填价的款也要保留
            statusText = "正在拉价格表…"
            let priceRows = try await WPSClient.pullAll(
                token: settings.priceToken.isEmpty ? settings.inventoryToken : settings.priceToken,
                fileId: settings.priceFileId,
                scriptId: settings.priceScriptId,
                argv: ["mode": "codes", "field": "单价/码", "sum": "0",
                       "gap": "1", "dropEmpty": "0", "money": "1"]
            )

            var priceMap: [String: (String?, Double?)] = [:]
            for row in priceRows {
                guard let code = pick(row, ["编号", "sku", "code"]) else { continue }
                let text = pick(row, ["单价/码", "单价", "价格"])
                priceMap[code.uppercased()] = (text, parseNumber(text))
            }

            var result: [Product] = []
            var seen = Set<String>()
            for row in stockRows {
                guard let code = pick(row, ["编号", "sku", "code"]) else { continue }
                let key = code.uppercased()
                if seen.contains(key) { continue }
                seen.insert(key)

                let qtyText = pick(row, ["库存", "数量", "qty"])
                let qty = parseNumber(qtyText)
                let p = priceMap[key]
                result.append(Product(
                    sku: code,
                    name: nil,
                    priceText: p?.0,
                    price: p?.1,
                    qty: qty,
                    qtyText: qtyText,
                    minQty: nil
                ))
            }

            // 价格表里有、库存表里没有的款也带上（方便查价）
            for (key, value) in priceMap where !seen.contains(key) {
                result.append(Product(
                    sku: key,
                    name: nil,
                    priceText: value.0,
                    price: value.1,
                    qty: nil,
                    qtyText: nil,
                    minQty: nil
                ))
            }

            result.sort { $0.sku.localizedStandardCompare($1.sku) == .orderedAscending }
            products = result
            lastSync = Date()
            saveProducts()
            statusText = "同步成功：\(result.count) 个款（\(lastSyncText)）"
        } catch {
            statusText = "同步失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 工具

    private func pick(_ row: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let v = row[k] {
                if let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    return s.trimmingCharacters(in: .whitespaces)
                }
                if let n = v as? NSNumber {
                    return n.stringValue
                }
                if let d = v as? Double {
                    return String(format: "%g", d)
                }
            }
        }
        return nil
    }

    /// 只处理纯数字和简单算式，其它返回 nil
    private func parseNumber(_ text: String?) -> Double? {
        guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        var s = raw
            .replacingOccurrences(of: "，", with: "+")
            .replacingOccurrences(of: ",", with: "+")
            .replacingOccurrences(of: "、", with: "+")
            .replacingOccurrences(of: "＋", with: "+")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: " ", with: "")
        if s.hasSuffix("+") { s.removeLast() }
        if let v = Double(s) { return v }

        let parts = s.split(separator: "+")
        if parts.count > 1 {
            var total: Double = 0
            for part in parts {
                if let v = Double(part) { total += v }
                else if part.contains("*") {
                    let sub = part.split(separator: "*").compactMap { Double($0) }
                    if sub.count == 2 { total += sub[0] * sub[1] } else { return nil }
                } else { return nil }
            }
            return total
        }
        return nil
    }
}
