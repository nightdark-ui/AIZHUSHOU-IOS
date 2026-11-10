import Foundation
import Combine
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
    @Published var history: [HistoryItem] = []
    @Published var historyLoading = false
    @Published var modelStatus = ""
    @Published var syncingAcks = false
    @Published var pendingAcks = 0
    @Published var lastAcksMessage = ""
    let library = ImageLibrary()
    private var libraryCancellable: AnyCancellable?
    @Published var lastSync: Date?
    @Published var lastPriceSync: Date?

    private var lastTurn: RuleTurn?
    private var lastSku: String?
    private let settingsKey = "aizhushou.settings.v1"
    private let lastSyncKey = "aizhushou.lastsync"
    private let lastPriceKey = "aizhushou.lastprice"

    init() {
        loadSettings()
        Notifier.requestPermission()
        if library.hasFolder { Task { await library.rebuild() } }
        pendingAcks = Storage.pendingCount()
        libraryCancellable = library.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        products = Storage.loadProducts()
        if !products.isEmpty {
            statusText = "本地有 \(products.count) 个款"
        }
        if let t = UserDefaults.standard.object(forKey: lastSyncKey) as? Date {
            lastSync = t
        }
        if let t = UserDefaults.standard.object(forKey: lastPriceKey) as? Date {
            lastPriceSync = t
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

    /// 只要时间：17:42
    var lastSyncTimeText: String {
        guard let d = lastSync else { return "未同步" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    var lastSyncText: String {
        guard let d = lastSync else { return "未同步" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    private func welcomeText() -> String {
        if products.isEmpty {
            return "主人，我是你的 AI 小助手。\n先去「设置」填 WPS 令牌，然后下拉同步。"
        }
        return "主人，我是你的 AI 小助手。\n可以这样问我：\n· 2002 库存\n· 2002 多少钱\n· 2002 有没有300\n· 有什么要补货的"
    }

    // MARK: - 设置

    func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return }
        settings = s
    }

    func saveSettings() {
        // 列名固定用默认值（界面上不给改）
        settings.fieldCode = "编号"
        settings.fieldQty = "库存"
        settings.fieldPrice = "单价/码"
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
        statusText = "设置已保存"
    }

    /// 设置页「保存并同步」：库存 + 价格全拉
    func saveAndSync() async {
        saveSettings()
        await sync(prices: true)
    }

    // MARK: - 同步

    func sync(prices: Bool = true) async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        do {
            statusText = "正在拉库存表…"
            let stockRows = try await WPSClient.pullAll(
                token: settings.inventoryToken,
                fileId: settings.inventoryFileId,
                scriptId: settings.inventoryScriptId,
                argv: ["mode": "codes",
                       "field": settings.fieldQty.isEmpty ? "库存" : settings.fieldQty,
                       "sum": "0",
                       "gap": "4", "dropEmpty": "1", "money": "0"]
            )

            // 价格表：只有"完整同步"时才拉
            var priceMap: [String: (String?, Double?)] = [:]
            if prices {
                statusText = "正在拉价格表…"
                let priceRows = try await WPSClient.pullAll(
                    token: settings.priceToken.isEmpty ? settings.inventoryToken : settings.priceToken,
                    fileId: settings.priceFileId,
                    scriptId: settings.priceScriptId,
                    argv: ["mode": "codes",
                           "field": settings.fieldPrice.isEmpty ? "单价/码" : settings.fieldPrice,
                           "sum": "0",
                           "gap": "1", "dropEmpty": "0", "money": "1"]
                )
                for row in priceRows {
                    guard let code = pick(row, [settings.fieldCode, "编号", "sku", "code"]) else { continue }
                    let text = pick(row, [settings.fieldPrice, "单价/码", "单价", "价格"])
                    priceMap[code.uppercased()] = (text, parseNumber(text))
                }
            } else {
                // 只更新库存：沿用本地已有的价格
                for p in products {
                    priceMap[p.sku.uppercased()] = (p.priceText, p.price)
                }
            }

            var result: [Product] = []
            var seen = Set<String>()
            for row in stockRows {
                guard let code = pick(row, [settings.fieldCode, "编号", "sku", "code"]) else { continue }
                let key = code.uppercased()
                if seen.contains(key) { continue }
                seen.insert(key)

                let qtyText = pick(row, [settings.fieldQty, "库存", "数量", "qty"])
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

            // 保留用户手工设过的单款提醒线
            var minMap: [String: Double] = [:]
            for p in products { if let m = p.minQty { minMap[p.sku] = m } }
            for idx in result.indices {
                if let m = minMap[result[idx].sku] { result[idx].minQty = m }
            }

            result.sort { $0.sku.localizedStandardCompare($1.sku) == .orderedAscending }
            products = result
            Storage.saveProducts(result)

            Storage.recordSnapshot(result, day: today)

            // 本地还没有历史快照 → 找电脑要一份，否则永远判不了"库存减少"
            if Storage.previousSnapshot(before: today) == nil {
                await importBaselineFromPC()
            }

            restock = RestockEngine.build(products: result, day: today,
                                          threshold: settings.threshold,
                                          acks: Storage.loadAcks())

            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: lastSyncKey)
            if prices {
                lastPriceSync = Date()
                UserDefaults.standard.set(lastPriceSync, forKey: lastPriceKey)
            }
            statusText = "同步成功：\(result.count) 个款，补货 \(restock.count) 个（\(lastSyncText)）"
                + (prices ? "" : " · 仅库存")

            Notifier.notifyRestockIfNeeded(count: restock.count,
                                       skus: restock.map { $0.sku },
                                       detail: restock.map { ($0.sku, $0.prevQty ?? 0, $0.qty ?? 0) })
            await syncAcks()
        } catch {
            statusText = "同步失败：\(error.localizedDescription)"
        }
    }

    /// 冷启动：库存 + 价格都拉（价格 10 分钟内不重复拉）
    func launchSync() {
        guard !syncing, !settings.inventoryToken.isEmpty else { return }
        let needPrice: Bool
        if let t = lastPriceSync {
            needPrice = Date().timeIntervalSince(t) > 600
        } else {
            needPrice = true
        }
        Task { await sync(prices: needPrice) }
    }

    /// 切回前台：只更新库存
    func autoSyncIfNeeded() {
        guard !syncing, !settings.inventoryToken.isEmpty else { return }
        if let last = lastSync, Date().timeIntervalSince(last) < 600 { return }
        Task { await sync(prices: false) }
    }

    /// 改单个款的提醒线（nil = 恢复默认）
    func setMinQty(sku: String, value: Double?) {
        guard let idx = products.firstIndex(where: { $0.sku == sku }) else { return }
        products[idx].minQty = value
        Storage.saveProducts(products)
        restock = RestockEngine.build(products: products, day: today,
                                      threshold: settings.threshold,
                                      acks: Storage.loadAcks())
        statusText = value == nil
            ? "\(sku) 已恢复默认提醒线"
            : "\(sku) 提醒线设为 \(Int(value!))"
    }

    /// 从电脑补一份基准快照
    private func importBaselineFromPC() async {
        let base = settings.pcBaseURL.trimmingCharacters(in: .whitespaces)
        let key = settings.syncKey.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !key.isEmpty else { return }
        do {
            if let b = try await SyncClient.baseline(base: base, key: key) {
                Storage.importBaseline(day: b.day, values: b.values)
                statusText += "（已补基准快照 \(b.day)）"
            }
        } catch {
            // 电脑没开就等下一次
        }
    }

    /// 重算补货清单（不重新拉表格）
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
        pendingAcks = Storage.pendingCount()
        Notifier.notifyRestockIfNeeded(count: restock.count,
                                       skus: restock.map { $0.sku },
                                       detail: restock.map { ($0.sku, $0.prevQty ?? 0, $0.qty ?? 0) })
        Task {
            await syncAcks()
            await loadHistory()
        }
    }

    // MARK: - 补货历史

    func loadHistory() async {
        let base = settings.pcBaseURL.trimmingCharacters(in: .whitespaces)
        let key = settings.syncKey.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !key.isEmpty else { return }

        historyLoading = true
        defer { historyLoading = false }
        do {
            let rows = try await SyncClient.history(base: base, key: key)
            history = rows.compactMap { HistoryItem(row: $0) }
        } catch {
            statusText = "拉历史失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 模型状态

    func testModel() async {
        guard !settings.deepSeekKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            modelStatus = "未配置"
            return
        }
        modelStatus = "检测中…"
        let t0 = Date()
        do {
            _ = try await DeepSeekClient.ask(question: "只回复两个字母：ok",
                                             key: settings.deepSeekKey,
                                             context: "", history: [])
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            modelStatus = "在线 \(ms)ms"
        } catch {
            modelStatus = "连不上"
        }
    }

    var modelConfigured: Bool {
        !settings.deepSeekKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - 和电脑双向同步

    /// 推自己的确认记录 + 拉电脑的，最后合并
    @discardableResult
    func syncAcks() async -> String {
        let base = settings.pcBaseURL.trimmingCharacters(in: .whitespaces)
        let key = settings.syncKey.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !key.isEmpty else {
            let msg = "还没填电脑地址或同步密钥"
            lastAcksMessage = msg
            return msg
        }

        syncingAcks = true
        defer { syncingAcks = false }

        // 本地确认记录 → 发给电脑
        let today = self.today
        var pushList: [[String: Any]] = []
        for raw in Storage.loadAcks() {
            let parts = raw.components(separatedBy: "|")
            guard parts.count == 3 else { continue }
            var item: [String: Any] = ["sku": parts[0], "prev_date": parts[1],
                                       "ack_date": today,
                                       "ack_at": ISO8601DateFormatter().string(from: Date())]
            if let q = Double(parts[2]) { item["qty"] = Int(q) }
            pushList.append(item)
        }

        // 本地单款提醒线
        var thresholds: [[String: Any]] = []
        for p in products where p.minQty != nil {
            thresholds.append(["sku": p.sku, "min_qty": Int(p.minQty!)])
        }

        do {
            let result = try await SyncClient.push(base: base, key: key,
                                                   acks: pushList, thresholds: thresholds)

            var added = 0
            for a in result.acks {
                guard let sku = a["sku"] as? String else { continue }
                let prev = a["prev_date"] as? String ?? ""
                let qty = (a["qty"] as? NSNumber)?.doubleValue
                let k = Storage.ackKey(sku: sku, prevDate: prev, qty: qty)
                if !Storage.loadAcks().contains(k) {
                    Storage.addAck(k)
                    added += 1
                }
            }

            var changed = 0
            var changedNames: [String] = []
            for t in result.thresholds {
                guard let sku = t["sku"] as? String else { continue }
                let v = (t["min_qty"] as? NSNumber)?.doubleValue
                if let idx = products.firstIndex(where: { $0.sku == sku }) {
                    if products[idx].minQty != v {
                        products[idx].minQty = v
                        changed += 1
                        changedNames.append("\(sku) → \(v.map { String(Int($0)) } ?? "默认")")
                    }
                }
            }
            if changed > 0 { Storage.saveProducts(products) }

            restock = RestockEngine.build(products: products, day: today,
                                          threshold: settings.threshold,
                                          acks: Storage.loadAcks())
            Notifier.notifyRestockIfNeeded(count: restock.count,
                                       skus: restock.map { $0.sku },
                                       detail: restock.map { ($0.sku, $0.prevQty ?? 0, $0.qty ?? 0) })
            // 标记这些确认已经送到电脑
            let pushedKeys = pushList.compactMap { item -> String? in
                guard let sku = item["sku"] as? String,
                      let prev = item["prev_date"] as? String else { return nil }
                let qty = (item["qty"] as? NSNumber)?.doubleValue
                return Storage.ackKey(sku: sku, prevDate: prev, qty: qty)
            }
            Storage.addPushed(pushedKeys)
            pendingAcks = Storage.pendingCount()

            var msg = "同步成功：电脑共 \(result.acks.count) 条确认，新增 \(added) 条"
            if changed > 0 {
                let shown = changedNames.prefix(5).joined(separator: "、")
                let more = changedNames.count > 5 ? " 等 \(changedNames.count) 个" : ""
                msg += "，提醒线改了 \(changed) 个：\(shown)\(more)"
            } else {
                msg += "，提醒线没有变化"
            }
            lastAcksMessage = msg
            statusText = msg
            return msg
        } catch {
            let msg = "同步失败：\(error.localizedDescription)"
            lastAcksMessage = msg
            statusText = msg
            return msg
        }
    }

    /// 一次确认多条
    func ackMany(_ items: [RestockItem]) {
        guard !items.isEmpty else { return }
        for item in items {
            let key = Storage.ackKey(sku: item.sku, prevDate: item.prevDate, qty: item.qty)
            Storage.addAck(key)
        }
        let skus = Set(items.map { $0.sku })
        restock.removeAll { skus.contains($0.sku) }
        pendingAcks = Storage.pendingCount()
        Notifier.notifyRestockIfNeeded(count: restock.count,
                                       skus: restock.map { $0.sku },
                                       detail: restock.map { ($0.sku, $0.prevQty ?? 0, $0.qty ?? 0) })
        Task { await syncAcks() }
    }

    // MARK: - 对话

    func ask(_ text: String) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        chat.append(ChatLine(role: "user", text: question, mode: ""))

        // 上一轮问过某个编号，这轮只说「价格呢」「库存呢」→ 拼上上次的编号
        var effective = question
        let intentWords = ["价格", "多少钱", "库存", "还有多少", "剩多少", "有货",
                           "图片", "照片", "长什么样", "米"]
        if Rules.extractCodes(effective).isEmpty, let last = lastSku,
           intentWords.contains(where: { effective.contains($0) }) {
            effective = effective + " " + last
        }

        // 先走规则
        let result = Rules.answer(effective, products: products,
                                  restock: restock, threshold: settings.threshold,
                                  turn: lastTurn)
        if let code = Rules.extractCodes(effective).first,
           let hit = Rules.find(code, in: products) {
            lastSku = hit.sku
        }
        lastTurn = result.turn
        if let answer = result.text {
            var line = ChatLine(role: "assistant", text: greet(answer), mode: "rule")
            line.images = imagesFor(question: effective, answer: answer)
            if let turn = result.turn, turn.kind == "choose" {
                line.options = turn.options
            }
            let wantsImage = effective.contains("图片") || effective.contains("照片")
            if wantsImage && line.images.isEmpty && line.options.isEmpty {
                line.text += "\n（图库里没找到这个编号的图，检查设置里的图库文件夹）"
            }
            chat.append(line)
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
                                                     history: chat,
                                                     base: settings.apiBase,
                                                     model: settings.apiModel)
            // 数字校验：AI 不能编数据
            if Rules.numbersOK(answer: reply, evidence: context, extra: question) {
                var line = ChatLine(role: "assistant", text: greet(reply), mode: "llm")
                line.images = imagesFor(question: question, answer: reply)
                chat.append(line)
            } else {
                chat.append(ChatLine(role: "assistant",
                                     text: "主人，AI 报的数字跟表格对不上，我就不照着说了。\n你问具体编号的库存或价格，我直接查给你。",
                                     mode: "rule"))
            }
        } catch {
            let msg: String
            if settings.deepSeekKey.trimmingCharacters(in: .whitespaces).isEmpty {
                msg = "主人，这个问题要联网的 AI 才能答，先去「设置 → AI 对话」填 DeepSeek API Key。\n"
                    + "现在本地能直接答的有：\n"
                    + "· 编号查库存/价格（2002 库存）\n"
                    + "· 编号区间（2001-2010）\n"
                    + "· 价格区间（10元左右 / 价格10到20）\n"
                    + "· 比某个编号贵/便宜（比2002贵的）\n"
                    + "· 有什么要补货的"
            } else {
                msg = "主人，这个问题需要联网的 AI，但现在用不了：\(error.localizedDescription)"
            }
            chat.append(ChatLine(role: "assistant", text: msg, mode: "rule"))
        }
    }

    /// 给 AI 的上下文：只带消息里提到的编号 + 补货清单
    private func buildContext(for question: String) -> String {
        var parts: [String] = []
        let codes = Rules.extractCodes(question)
        for code in codes.prefix(8) {
            if let p = Rules.find(code, in: products) {
                parts.append("\(p.sku)  价 \(p.priceText ?? "未填")  库存 \(p.qtyText ?? p.qty.map { String(Int($0)) } ?? "未知")")
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

    /// 什么时候配图，配几张：
    ///   问了「图片」→ 每个编号各出一张（最多 6 个）
    ///   没问图片   → 只给单个编号的预览图（最多 2 张）
    private func imagesFor(question: String, answer: String) -> [String] {
        guard library.hasFolder else { return [] }

        let wantsImage = question.contains("图") || question.contains("照片")
            || question.contains("看看") || question.contains("长什么样")
        let codes = Rules.extractCodes(question)
        guard !codes.isEmpty else { return [] }

        if codes.count > 1 {
            guard wantsImage else { return [] }
            var out: [String] = []
            for c in codes.prefix(6) {
                guard let p = Rules.find(c, in: products) else { continue }
                if let first = library.images(for: p.sku, limit: 1).first {
                    out.append(first)
                }
            }
            return out
        }

        guard let p = Rules.find(codes[0], in: products) else { return [] }
        return library.images(for: p.sku, limit: wantsImage ? 4 : 2)
    }

    /// 统一称呼：回答开头叫「主人」
    private func greet(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return t }
        if t.hasPrefix("主人") { return t }
        return "主人，" + t
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
