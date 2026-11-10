import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {

    @Published var settings: AppSettings = AppSettings()
    @Published var products: [Product] = []
    @Published var restock: [RestockItem] = []
    @Published var chat: [ChatLine] = []
    @Published var syncing = false
    @Published var thinking = false
    @Published var statusText = "还没同步"
    @Published var lastSync: Date?

    private let settingsKey = "aizhushou.settings.v1"
    private let lastSyncKey = "aizhushou.lastsync"

    init() {
        loadSettings()
        products = Storage.loadProducts()
        if !products.isEmpty {
            statusText = "本地有 \(products.count) 个款"
        }
        if let t = UserDefaults.standard.object(forKey: lastSyncKey) as? Date {
            lastSync = t
        }
        restock = RestockEngine.build(products: products, day: today, threshold: settings.threshold,
                                      acks: Storage.loadAcks())
        chat = [ChatLine(role: "assistant",
                         text: welcomeText(),
                         mode: "rule")]
    }

    var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var lastSyncText: String {
        guard let d = lastSync else { return "未同步" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    private func welcomeText() -> String {
        if products.isEmpty {
            return "你好，我是你的 AI 小助手。\n先去「设置」填 WPS 令牌，然后下拉同步。"
        }
        return "你好，我是你的 AI 小助手。\n可以这样问我：\n· 2002 库存\n· 2002 多少钱\n· 2002 有没有300\n· 有什么要补货的"
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

    // MARK: - 同步

    func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        do {
            statusText = "正在拉库存表…"
            let stockRows = try await WPSClient.pullAll(
                token: settings.inventoryToken,
                fileId: settings.inventoryFileId,
                scriptId: settings.inventoryScriptId,
                argv: ["mode": "codes", "field": "库存", "sum": "0",
                       "gap": "4", "dropEmpty": "1", "money": "0"]
            )

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
                let qty = normalizeQty(qtyText)
                let p = priceMap[key]
                result.append(Product(sku: code, name: nil,
                                      priceText: p?.0, price: p?.1,
                                      qty: qty, qtyText: qtyText, minQty: nil))
            }
            for (key, value) in priceMap where !seen.contains(key) {
                result.append(Product(sku: key, name: nil,
                                      priceText: value.0, price: value.1,
                                      qty: nil, qtyText: nil, minQty: nil))
            }

            result.sort { $0.sku.localizedStandardCompare($1.sku) == .orderedAscending }
            products = result
            Storage.saveProducts(result)

            // 记今天的快照（同一天覆盖）
            Storage.recordSnapshot(result, day: today)

            restock = RestockEngine.build(products: result, day: today,
                                          threshold: settings.threshold,
                                          acks: Storage.loadAcks())

            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: lastSyncKey)
            statusText = "同步成功：\(result.count) 个款，补货 \(restock.count) 个（\(lastSyncText)）"
        } catch {
            statusText = "同步失败：\(error.localizedDescription)"
        }
    }

    /// 重新算一遍补货清单（不重新同步表格）
    func refreshRestock() async {
        restock = RestockEngine.build(products: products, day: today,
                                      threshold: settings.threshold,
                                      acks: Storage.loadAcks())
    }

    // MARK: - 补货确认

    func ack(_ item: RestockItem) {
        let key = Storage.ackKey(sku: item.sku, prevDate: item.prevDate, qty: item.qty)
        Storage.addAck(key)
        restock.removeAll { $0.sku == item.sku }
    }

    // MARK: - 对话

    func ask(_ text: String) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        chat.append(ChatLine(role: "user", text: question, mode: ""))

        // 先走规则
        if let answer = Rules.answer(question, products: products,
                                     restock: restock, threshold: settings.threshold) {
            chat.append(ChatLine(role: "assistant", text: answer, mode: "rule"))
            return
        }

        // 规则答不了 → AI
        thinking = true
        defer { thinking = false }

        let context = buildContext(for: question)
        do {
            let reply = try await DeepSeekClient.ask(question: question,
                                                     key: settings.deepSeekKey,
                                                     context: context,
                                                     history: chat)
            chat.append(ChatLine(role: "assistant", text: reply, mode: "llm"))
        } catch {
            chat.append(ChatLine(role: "assistant",
                                 text: "这个问题需要联网的 AI，但现在用不了：\(error.localizedDescription)",
                                 mode: "rule"))
        }
    }

    /// 给 AI 的上下文：只带消息里提到的编号 + 补货清单
    private func buildContext(for question: String) -> String {
        var parts: [String] = []
        let codes = Rules.extractCodes(question)
        for code in codes.prefix(8) {
            if let p = Rules.find(code, in: products) {
                parts.append("\(p.sku)  价 \(p.priceText ?? "未填")  库存 \(p.qty.map { String(Int($0)) } ?? "未知")")
            }
        }
        if !restock.isEmpty {
            parts.append("【补货清单】")
            for item in restock.prefix(15) {
                parts.append("\(item.sku)  少了 \(Int(abs(item.change)))  剩 \(Int(item.qty ?? 0))")
            }
        }
        if parts.isEmpty {
            parts.append("（用户没提具体编号，也没有补货记录）")
        }
        return parts.joined(separator: "\n")
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
            }
        }
        return nil
    }

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

    private func normalizeQty(_ text: String?) -> Double? {
        guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let v = parseNumber(raw) { return v }
        if raw.contains("没货") || raw.contains("无货") { return 0 }
        return nil
    }
}
