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
    /// 本次同步开始时间（用于超时看门狗）
    @Published var syncStartedAt: Date?
    /// 当前在同步什么（库存 / 库存+价格）
    @Published var syncStage = ""
    private var syncTask: Task<Void, Never>?
    @Published var thinking = false
    @Published var statusText = "还没同步"
    @Published var history: [HistoryItem] = []
    @Published var historyLoading = false
    @Published var modelStatus = ""
    @Published var syncingAcks = false
    @Published var pendingAcks = 0
    @Published var backupMessage = ""
    @Published var lastSyncFailed = false
    @Published var syncWarning = ""
    /// 单项数量超过上限的款（可能是两个数字粘在一起）
    @Published var qtyIssues: [QtyIssue] = []
    @Published var lastAcksMessage = ""
    let library = ImageLibrary()
    private var libraryCancellable: AnyCancellable?
    @Published var lastSync: Date?
    @Published var lastPriceSync: Date?
    @Published var lastSnapshotSync: Date?
    /// 刚刚创建今日基准时记一下（页面用来提示）
    @Published var baselineJustCreated: (day: String, count: Int)?

    private var lastTurn: RuleTurn?
    private var lastSku: String?
    private var lastIntent = ""
    private var lastCodes: [String] = []
    /// 上一轮列表回答里列出的款号（用于「全部给我图片」）
    private var lastListSkus: [String] = []
    private var lastAskStamp: (text: String, at: Date)?
    private let settingsKey = "aizhushou.settings.v1"
    private let lastSyncKey = "aizhushou.lastsync"
    private let lastPriceKey = "aizhushou.lastprice"

    init() {
        loadSettings()
        Notifier.requestPermission()
        if library.hasFolder { Task { await library.rebuild() } }
        pendingAcks = Storage.pendingCount()
        history = Storage.loadLocalHistory()
        qtyIssues = QtyCheck.analyze(products, ignored: Storage.loadIgnoredQty())
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
        syncStartedAt = Date()
        syncStage = prices ? "库存+价格" : "库存"
        defer {
            syncing = false
            syncStartedAt = nil
            syncStage = ""
        }

        do {
            var stockRows: [[String: Any]] = []
            statusText = "正在拉库存表…"

            // 库存表和价格表同时拉（每张表一次请求就能拿全）
            async let stockTask = WPSClient.pullAll(
                token: settings.inventoryToken,
                fileId: settings.inventoryFileId,
                scriptId: settings.inventoryScriptId,
                argv: ["mode": "codes",
                       "field": settings.fieldQty.isEmpty ? "库存" : settings.fieldQty,
                       "sum": "0",
                       "gap": "4", "dropEmpty": "1", "money": "0"]
            )

            var priceMap: [String: (String?, Double?)] = [:]

            if prices {
                async let priceTask = WPSClient.pullAll(
                    token: settings.priceToken.isEmpty ? settings.inventoryToken : settings.priceToken,
                    fileId: settings.priceFileId,
                    scriptId: settings.priceScriptId,
                    argv: ["mode": "codes",
                           "field": settings.fieldPrice.isEmpty ? "单价/码" : settings.fieldPrice,
                           "sum": "0",
                           "gap": "1", "dropEmpty": "0", "money": "1"]
                )
                let pair = try await (stockTask, priceTask)
                stockRows = pair.0
                for row in pair.1 {
                    guard let code = pick(row, [settings.fieldCode, "编号", "sku", "code"]) else { continue }
                    let text = pick(row, [settings.fieldPrice, "单价/码", "单价", "价格"])
                    priceMap[code.uppercased()] = (text, parseNumber(text))
                }
            } else {
                // 只更新库存：沿用本地已有的价格
                for p in products {
                    priceMap[p.sku.uppercased()] = (p.priceText, p.price)
                }
                stockRows = try await stockTask
            }

            syncStage = "整理数据"
            statusText = "正在整理数据…"

            var result: [Product] = []
            var seen = Set<String>()
            for row in stockRows {
                guard let code = pick(row, [settings.fieldCode, "编号", "sku", "code"]) else { continue }
                // 明显不是款号的行（没货 / 散剪 / 加工费 …）直接跳过
                if isNotASku(code) { continue }
                let key = code.uppercased()
                if seen.contains(key) { continue }
                seen.insert(key)

                let qtyText = pick(row, [settings.fieldQty, "库存", "数量", "qty"])
                // 数量空白 → 当没货（0）；有文字但算不出 → 保持 unknown
                let qty = normalizeQty(qtyText) ?? ((qtyText ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? 0 : nil)
                let p = priceMap[key]
                result.append(Product(sku: code, name: nil,
                                      priceText: p?.0, price: p?.1,
                                      qty: qty, qtyText: qtyText, minQty: nil))
            }
            for (key, value) in priceMap where !seen.contains(key) {
                if isNotASku(key) { continue }
                // 只有价格、没有库存行 → 表格里库存是空的，按没货算
                result.append(Product(sku: key, name: nil,
                                      priceText: value.0, price: value.1,
                                      qty: 0, qtyText: nil, minQty: nil))
            }

            // 保留用户手工设过的单款提醒线
            var minMap: [String: Double] = [:]
            for p in products { if let m = p.minQty { minMap[p.sku] = m } }
            for idx in result.indices {
                if let m = minMap[result[idx].sku] { result[idx].minQty = m }
            }

            result.sort { $0.sku.localizedStandardCompare($1.sku) == .orderedAscending }

            // 数据骤减保护：明显少了一大截就不覆盖，免得把好数据冲掉
            let before = products.count
            if before > 200, result.count < before - max(50, before / 5) {
                lastSyncFailed = true
                syncWarning = "同步异常：这次只拿到 \(result.count) 个款（上次 \(before) 个），已保留旧数据。"
                statusText = syncWarning
                return
            }

            products = result
            Storage.saveProducts(result)

            Storage.recordSnapshot(result, day: today)

            // 没有历史快照 → 用当天第一次的库存当基准，这样当天再变化也能提醒
            var dayBaseline: [String: Double]? = Storage.previousSnapshot(before: today) == nil
                ? Storage.todayBaseline(for: today)
                : nil
            if Storage.previousSnapshot(before: today) == nil, dayBaseline == nil {
                var snap: [String: Double] = [:]
                for p in result { if let q = p.qty { snap[p.sku] = q } }
                if Storage.setTodayBaseline(day: today, values: snap) {
                    dayBaseline = snap
                    baselineJustCreated = (day: today, count: snap.count)
                    Notifier.notifyBaselineCreated(count: snap.count)
                }
            }

            restock = RestockEngine.build(products: result, day: today,
                                          threshold: settings.threshold,
                                          acks: Storage.loadAcks(),
                                          dayBaseline: dayBaseline)

            lastSync = Date()
            lastSyncFailed = false
            syncWarning = ""
            UserDefaults.standard.set(lastSync, forKey: lastSyncKey)
            if prices {
                lastPriceSync = Date()
                UserDefaults.standard.set(lastPriceSync, forKey: lastPriceKey)
            }
            qtyIssues = QtyCheck.analyze(result, ignored: Storage.loadIgnoredQty())
            statusText = "同步成功：\(result.count) 个款，补货 \(restock.count) 个（\(lastSyncText)）"
                + (prices ? "" : " · 仅库存")

            Notifier.notifyRestockIfNeeded(count: restock.count,
                                       skus: restock.map { $0.sku },
                                       detail: restock.map { ($0.sku, $0.prevQty ?? 0, $0.qty ?? 0) })

            // 电脑推送不在这里做：只刷新本地待推送条数，
            // 什么时候推由「设置 → 电脑端同步状态」手动触发
            pendingAcks = Storage.pendingCount()
        } catch {
            lastSyncFailed = true
            statusText = "同步失败：\(error.localizedDescription)"
        }
    }

    /// 用统一入口启动同步（记住任务句柄，超时能取消）
    func startSync(prices: Bool) {
        guard !syncing else { return }
        syncTask?.cancel()
        syncTask = Task { await sync(prices: prices) }
    }

    /// 看门狗：同步卡住超过 90 秒就强制复位并取消
    func watchdogSync() {
        guard syncing, let start = syncStartedAt else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 90 else { return }
        syncTask?.cancel()
        syncTask = nil
        syncing = false
        syncStartedAt = nil
        lastSyncFailed = true
        statusText = "同步超时已取消（\(Int(elapsed)) 秒），请检查网络后重试"
    }

    /// 同步已经进行多久（秒），没在同步返回 nil
    var syncElapsed: Int? {
        guard syncing, let start = syncStartedAt else { return nil }
        return max(0, Int(Date().timeIntervalSince(start)))
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
        startSync(prices: needPrice)
    }

    /// 切回前台：只更新库存（5 分钟内不重复）
    /// 切回前台：立刻同步（20 秒防抖，避免连点）
    func autoSyncIfNeeded() {
        guard !syncing, !settings.inventoryToken.isEmpty else { return }
        if let last = lastSync, Date().timeIntervalSince(last) < 20 { return }
        startSync(prices: false)
    }

    /// App 一直开着时，每 5 分钟自动拉一次库存
    func periodicSyncIfNeeded() {
        guard !syncing, !settings.inventoryToken.isEmpty else { return }
        if let last = lastSync, Date().timeIntervalSince(last) < 300 { return }
        startSync(prices: false)
    }

    /// 改单个款的提醒线（nil = 恢复默认）
    func setMinQty(sku: String, value: Double?) {
        guard let idx = products.firstIndex(where: { $0.sku == sku }) else { return }
        products[idx].minQty = value
        Storage.saveProducts(products)
        restock = RestockEngine.build(products: products, day: today,
                                      threshold: settings.threshold,
                                      acks: Storage.loadAcks(),
                                      dayBaseline: Storage.todayBaseline(for: today))
        statusText = value == nil
            ? "\(sku) 已恢复默认提醒线"
            : "\(sku) 提醒线设为 \(Int(value!))"
    }

    /// 从电脑拉最近 N 天快照补本地（重装、换机后恢复补货判断）
    @discardableResult
    /// 改默认提醒线后立刻生效（不用同步表格）
    func applyDefaultThreshold() {
        saveSettings()
        restock = RestockEngine.build(products: products, day: today,
                                      threshold: settings.threshold,
                                      acks: Storage.loadAcks(),
                                      dayBaseline: Storage.todayBaseline(for: today))
        qtyIssues = QtyCheck.analyze(products, ignored: Storage.loadIgnoredQty())
        statusText = "默认提醒线改为 \(Int(settings.threshold))，补货 \(restock.count) 个"
        Notifier.notifyRestockIfNeeded(count: restock.count,
                                       skus: restock.map { $0.sku },
                                       detail: restock.map { ($0.sku, $0.prevQty ?? 0, $0.qty ?? 0) })
    }

    /// 忽略一条数量异常（这个款数值再变化前不再报警）
    func ignoreQtyIssue(_ issue: QtyIssue) {
        Storage.addIgnoredQty(issue.ignoreKey)
        qtyIssues = QtyCheck.analyze(products, ignored: Storage.loadIgnoredQty())
        statusText = "已忽略 \(issue.sku) 的数量异常（数值再变会重新提示）"
    }

    /// 恢复全部忽略
    func resetIgnoredQty() {
        Storage.clearIgnoredQty()
        qtyIssues = QtyCheck.analyze(products, ignored: Storage.loadIgnoredQty())
        statusText = "已恢复全部数量异常提示"
    }

    /// 当前忽略了几条
    var ignoredQtyCount: Int { Storage.loadIgnoredQty().count }

    /// 有没有可对比的历史快照（没有就说明今天刚装上）
    var hasSnapshotBaseline: Bool {
        Storage.previousSnapshot(before: today) != nil
            || Storage.todayBaseline(for: today) != nil
    }

    /// 重算补货清单（不重新拉表格）
    func refreshRestock() async {
        restock = RestockEngine.build(products: products, day: today,
                                      threshold: settings.threshold,
                                      acks: Storage.loadAcks(),
                                      dayBaseline: Storage.todayBaseline(for: today))
    }

    // MARK: - 补货确认

    func ack(_ item: RestockItem) {
        let key = Storage.ackKey(sku: item.sku, prevDate: item.prevDate, qty: item.qty)
        Storage.addAck(key)
        Storage.appendLocalHistory([historyItem(from: item)])
        restock.removeAll { $0.sku == item.sku }
        pendingAcks = Storage.pendingCount()
        Notifier.notifyRestockIfNeeded(count: restock.count,
                                       skus: restock.map { $0.sku },
                                       detail: restock.map { ($0.sku, $0.prevQty ?? 0, $0.qty ?? 0) })
        // 确认只记在本地；推送由设置页手动触发
        Task { await loadHistory() }
    }

    /// 把一条补货记录转成历史条目（存在手机本地）
    private func historyItem(from item: RestockItem) -> HistoryItem {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return HistoryItem(sku: item.sku,
                           ackDate: today,
                           ackAt: formatter.string(from: Date()),
                           qty: item.qty,
                           prevQty: item.prevQty)
    }

    // MARK: - 补货历史

    func loadHistory() async {
        // 只读本机历史（不再连电脑）
        history = Storage.loadLocalHistory()
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

    /// 点追问按钮（还有吗 / 超过的也要）
    func tapQuick(_ text: String, lineID: UUID) {
        if let idx = chat.firstIndex(where: { $0.id == lineID }) {
            chat[idx].quickReplies = []
        }
        Task { await ask(text) }
    }

    /// 点候选编号：带上原来问的意图
    /// 点掉某个候选后，把这条消息的选项清空（防止连点/重复反问）
    func consumeOptions(lineID: UUID) {
        guard let idx = chat.firstIndex(where: { $0.id == lineID }) else { return }
        chat[idx].options = []
        chat[idx].optionIntent = ""
    }

    func chooseOption(_ sku: String, intent: String) {
        switch intent {
        case "price":
            Task { await ask(sku + " 价格", chosen: sku) }
        case "stock":
            Task { await ask(sku + " 库存", chosen: sku) }
        default:
            // 没指定问什么：回价格 + 库存 + 图
            Task { await ask(sku, chosen: sku) }
        }
    }

    // MARK: - 备份 / 恢复

    /// 导出备份，返回文件路径（成功后可以分享出去）
    func exportBackup() -> URL? {
        do {
            let url = try Backup.export(settings: settings,
                                        acks: Storage.loadAcks(),
                                        products: products)
            Backup.cleanupOld()
            backupMessage = "备份已生成：\(url.lastPathComponent)"
            return url
        } catch {
            backupMessage = "备份失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 从备份文件恢复
    func importBackup(from url: URL) {
        do {
            let pack = try Backup.load(from: url)
            let summary = apply(pack)
            backupMessage = "恢复完成：" + summary
        } catch {
            backupMessage = "恢复失败：\(error.localizedDescription)"
        }
    }

    /// 恢复备份：合并，不覆盖本地更新的数据
    ///   · 快照：同一天以本地为准，备份里独有的日期补进来
    ///   · 确认 / 已推送：取并集
    ///   · 补货历史：按 编号+日期 合并
    ///   · 最后用当前库存补一份今天的快照，保证对比基准不断档
    @discardableResult
    private func apply(_ pack: BackupFile) -> String {
        // ① 设置：整体恢复
        settings = pack.settings
        saveSettings()

        // ② 补货确认：并集（本地已有的不丢）
        var acks = Storage.loadAcks()
        let acksBefore = acks.count
        for a in pack.acks { acks.insert(a) }
        Storage.restoreAcks(Array(acks))

        // ③ 最后一次库存 + 价格快照
        var restoredProducts = 0
        if let saved = pack.products, !saved.isEmpty {
            // 保留本地手工设过的单款提醒线
            var minMap: [String: Double] = [:]
            for p in products { if let m = p.minQty { minMap[p.sku] = m } }
            var merged = saved
            for idx in merged.indices {
                if let m = minMap[merged[idx].sku] { merged[idx].minQty = m }
            }
            products = merged
            Storage.saveProducts(merged)
            restoredProducts = merged.count
        } else {
            products = Storage.loadProducts()
        }

        // ④ 用还原的库存当基准，这样当天再变化也能提醒
        if !products.isEmpty {
            var snap: [String: Double] = [:]
            for p in products { if let q = p.qty { snap[p.sku] = q } }
            Storage.setTodayBaseline(day: today, values: snap)
            Storage.recordSnapshot(products, day: today)
        }

        restock = RestockEngine.build(products: products, day: today,
                                      threshold: settings.threshold,
                                      acks: Storage.loadAcks(),
                                      dayBaseline: Storage.todayBaseline(for: today))
        qtyIssues = QtyCheck.analyze(products, ignored: Storage.loadIgnoredQty())
        pendingAcks = Storage.pendingCount()
        history = Storage.loadLocalHistory()
        lastSyncFailed = false
        syncWarning = ""
        statusText = "已从备份恢复（\(pack.createdAt)）"

        var parts: [String] = []
        parts.append("设置已恢复")
        parts.append("确认 +\(acks.count - acksBefore) 条")
        if restoredProducts > 0 { parts.append("库存 \(restoredProducts) 个款") }
        return parts.joined(separator: "，")
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
            return msg
        } catch {
            let msg = "同步失败：\(error.localizedDescription)"
            lastAcksMessage = msg
            return msg
        }
    }

    /// 一次确认多条
    func ackMany(_ items: [RestockItem]) {
        guard !items.isEmpty else { return }
        var records: [HistoryItem] = []
        for item in items {
            let key = Storage.ackKey(sku: item.sku, prevDate: item.prevDate, qty: item.qty)
            Storage.addAck(key)
            records.append(historyItem(from: item))
        }
        Storage.appendLocalHistory(records)
        let skus = Set(items.map { $0.sku })
        restock.removeAll { skus.contains($0.sku) }
        pendingAcks = Storage.pendingCount()
        Notifier.notifyRestockIfNeeded(count: restock.count,
                                       skus: restock.map { $0.sku },
                                       detail: restock.map { ($0.sku, $0.prevQty ?? 0, $0.qty ?? 0) })
        // 推送由设置页手动触发
    }

    // MARK: - 对话

    func ask(_ text: String, chosen: String? = nil) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        // 连点保护：1.2 秒内同样的提问只处理一次
        let stamp = question + "|" + (chosen ?? "")
        if let last = lastAskStamp, last.text == stamp,
           Date().timeIntervalSince(last.at) < 1.2 { return }
        lastAskStamp = (stamp, Date())

        chat.append(ChatLine(role: "user", text: question, mode: ""))

        // 「列表给我」「只列表」→ 用上次的款号紧凑重列（不带价格）
        let wantsListOnly = question.contains("列表")
            && !question.contains("价格")
            && Rules.extractCodes(question).isEmpty
        if wantsListOnly, !lastListSkus.isEmpty {
            var lines = [greet("这是刚才那 \(lastListSkus.count) 个款：")]
            for sku in lastListSkus {
                guard let p = products.first(where: { $0.sku == sku }) else { continue }
                lines.append("\(p.sku)  \(p.qty.map { "\(Int($0)) 码" } ?? "数量未填")")
            }
            var line = ChatLine(role: "assistant", text: lines.joined(separator: "\n"), mode: "rule")
            line.quickReplies = ["图片都给我"]
            chat.append(line)
            return
        }

        // 「全部给我图片」→ 把上一轮列表里的款都发图
        let wantsAllImages = (question.contains("图片") || question.contains("照片"))
            && (question.contains("全部") || question.contains("所有") || question.contains("都要")
                || question.contains("全都") || question.contains("每个")
                || question.contains("都给我") || question.contains("整批")
                || question.contains("这些") || question.contains("上面"))
        if wantsAllImages, lastListSkus.isEmpty {
            // 上一条回答是 AI 的也支持
            if let last = chat.last(where: { $0.role == "assistant" }) {
                let found = skusMentioned(in: last.text)
                if !found.isEmpty { lastListSkus = found }
            }
        }
        if wantsAllImages, !lastListSkus.isEmpty {
            var line = ChatLine(role: "assistant", text: greet("这是刚才列的 \(lastListSkus.count) 个款："), mode: "rule")
            var paths: [String] = []
            var withImage: [String] = []
            var without: [String] = []
            for sku in lastListSkus.prefix(24) {
                let imgs = library.images(for: sku, limit: 1)
                if let first = imgs.first {
                    if !paths.contains(first) { paths.append(first) }
                    withImage.append(sku)
                } else {
                    without.append(sku)
                }
            }
            line.images = paths
            if paths.isEmpty {
                line.text = greet("刚才列的 \(lastListSkus.count) 个款，图库里都没有图片。")
            } else {
                line.text = greet("这是刚才列的 \(lastListSkus.count) 个款，有图的 \(withImage.count) 个：\n"
                                  + withImage.joined(separator: "、"))
                if !without.isEmpty {
                    line.text += "\n（其余 \(without.count) 个图库没有："
                        + without.prefix(6).joined(separator: "、") + "）"
                }
            }
            chat.append(line)
            return
        }

        // 只说「图片呢」→ 用上一轮问到的全部编号
        let bareImage = Rules.extractCodes(question).isEmpty
            && (question.contains("图片") || question.contains("照片")
                || question.contains("长什么样"))
        if bareImage, lastCodes.isEmpty, !lastListSkus.isEmpty {
            lastCodes = lastListSkus
        }
        if bareImage, !lastCodes.isEmpty {
            var line = ChatLine(role: "assistant", text: greet("这是刚才问的款："), mode: "rule")
            line.images = imagesFor(question: question + " " + lastCodes.joined(separator: " "),
                                    answer: "")
            let missing = missingImageSkus(question: question + " " + lastCodes.joined(separator: " "))
            if !missing.isEmpty {
                line.text += "\n（图库里没有 \(missing.prefix(4).joined(separator: "、")) 款的图片）"
            }
            chat.append(line)
            return
        }

        // 上一轮问过某个编号，这轮只说「价格呢」「库存呢」→ 拼上上次的编号
        var effective = question
        let intentWords = ["价格", "多少钱", "库存", "还有多少", "剩多少", "有多少", "多少",
                           "有货", "图片", "照片", "长什么样", "米", "码"]

        // 没有编号、只说「价格呢」「库存呢」→ 沿用上一条编号
        if Rules.extractCodes(effective).isEmpty, let last = lastSku,
           intentWords.contains(where: { effective.contains($0) }) {
            effective = effective + " " + last
        }

        // 有编号、但没说问什么（如「2053呢」）→ 沿用上一轮意图
        if !lastIntent.isEmpty,
           !intentWords.contains(where: { effective.contains($0) }),
           !Rules.extractCodes(effective).isEmpty {
            effective = effective + " " + (lastIntent == "price" ? "价格" : "库存")
        }

        // 先走规则
        let result = Rules.answer(effective, products: products,
                                  restock: restock, threshold: settings.threshold,
                                  turn: lastTurn, chosen: chosen)
        if effective.contains("价格") || effective.contains("多少钱") {
            lastIntent = "price"
        } else if effective.contains("库存") || effective.contains("码") || effective.contains("米") {
            lastIntent = "stock"
        }

        let usedCodes = Rules.extractCodes(effective)
        if let code = usedCodes.first,
           let hit = Rules.find(code, in: products) {
            lastSku = hit.sku
        }
        if !usedCodes.isEmpty {
            lastCodes = usedCodes
        }
        lastTurn = result.turn
        if let skus = result.turn?.skus, !skus.isEmpty {
            lastListSkus = skus
        }
        if let answer = result.text {
            var line = ChatLine(role: "assistant", text: greet(answer), mode: "rule")
            line.lowConfidence = result.turn?.lowConfidence ?? false
            line.quickReplies = result.turn?.quick ?? []
            line.sourceQuestion = question
            line.images = imagesFor(question: effective, answer: answer)
            if let turn = result.turn, turn.kind == "choose" {
                line.options = turn.options
                line.optionIntent = turn.intent
            }
            let wantsImage = effective.contains("图片") || effective.contains("照片")
            if wantsImage && line.options.isEmpty {
                let missing = missingImageSkus(question: effective)
                if !missing.isEmpty {
                    line.text += "\n（图库里没有 \(missing.prefix(4).joined(separator: "、")) 款的图片）"
                }
            }
            chat.append(line)
            return
        }

        // 规则答不了 → AI
        thinking = true
        defer { thinking = false }

        let context = buildContext(for: question)
        do {
            let (reply, evidence) = try await DeepSeekClient.askWithTools(
                question: question,
                key: settings.deepSeekKey,
                history: chat,
                base: settings.apiBase,
                model: settings.apiModel,
                products: products,
                restock: restock
            )

            // 严格校验：数字和编号都必须来自工具数据
            var finalReply = reply
            var finalEvidence = evidence + "\n" + context

            if !Rules.strictCheck(answer: finalReply, evidence: finalEvidence, question: question) {
                // 给 AI 一次改正机会
                let retry = try? await DeepSeekClient.askWithTools(
                    question: question,
                    key: settings.deepSeekKey,
                    history: chat,
                    base: settings.apiBase,
                    model: settings.apiModel,
                    products: products,
                    restock: restock,
                    extraInstruction: "上一次回答里出现了表格数据里没有的数字或编号。这一次只能原样照抄工具返回值，不得推算、不得四舍五入、不得编造。"
                )
                if let retry, Rules.strictCheck(answer: retry.text,
                                                evidence: retry.evidence + "\n" + context,
                                                question: question) {
                    finalReply = retry.text
                    finalEvidence = retry.evidence + "\n" + context
                }
            }

            let (marked, issues) = Rules.markUnverified(answer: finalReply,
                                                        evidence: finalEvidence,
                                                        question: question)
            var text = greet(marked)
            if !issues.isEmpty {
                text += "\n\n⚠️ 上面标 ⚠️ 的 \(issues.count) 处（\(issues.prefix(5).joined(separator: "、"))）"
                text += "在表格里找不到，可能是 AI 推算的，请核对后再用。"
            }
            var line = ChatLine(role: "assistant", text: text, mode: "llm")
            line.images = imagesFor(question: question, answer: finalReply)
            chat.append(line)
            // 记下 AI 回答里出现过的款号（供「图片都给我」「列表给我」）
            let found = skusMentioned(in: text)
            if !found.isEmpty {
                lastListSkus = found
                lastCodes = found
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

    /// 这次问到的款里，哪些在图库中没有图片
    private func missingImageSkus(question: String) -> [String] {
        var codes = Rules.extractCodes(question)
        if codes.isEmpty { codes = lastCodes }
        guard !codes.isEmpty else { return [] }

        var missing: [String] = []
        for c in codes.prefix(6) {
            guard let p = Rules.find(c, in: products) else { continue }
            if library.images(for: p.sku, limit: 1).isEmpty {
                if !missing.contains(p.sku) { missing.append(p.sku) }
            }
        }
        return missing
    }

    /// 什么时候配图，配几张：
    ///   多编号 → 每个编号各一张（最多 6 个）
    ///   单编号 → 问图片最多 4 张，否则 2 张
    private func imagesFor(question: String, answer: String) -> [String] {
        guard library.hasFolder else { return [] }

        var wantsImage = question.contains("图") || question.contains("照片")
            || question.contains("看看") || question.contains("长什么样")

        var codes = Rules.extractCodes(question)

        // 只发了款号（没问价格/库存/别的）→ 当作要全套：价格+库存+图
        if !codes.isEmpty && !wantsImage {
            let stripped = question
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "，", with: "")
                .replacingOccurrences(of: ",", with: "")
            var rest = stripped
            for c in codes {
                rest = rest.replacingOccurrences(of: c, with: "")
            }
            if rest.isEmpty { wantsImage = true }
        }

        if codes.isEmpty, wantsImage { codes = lastCodes }
        guard !codes.isEmpty else { return [] }

        var out: [String] = []
        for c in codes.prefix(6) {
            guard let p = Rules.find(c, in: products) else { continue }
            let limit = codes.count == 1 ? (wantsImage ? 4 : 2) : 1
            for path in library.images(for: p.sku, limit: limit) where !out.contains(path) {
                out.append(path)
            }
        }
        return out
    }

    /// 从一段文字里找出真实存在、且确实被提到的款号
    private func skusMentioned(in text: String) -> [String] {
        var out: [String] = []
        for code in Rules.extractCodes(text) {
            guard let p = Rules.find(code, in: products) else { continue }
            if !out.contains(p.sku) { out.append(p.sku) }
        }
        return out
    }

    /// 这条规则回答不太确定 → 让 AI 重新答一次（追加在下面）
    func askAI(for lineID: UUID) {
        guard let idx = chat.firstIndex(where: { $0.id == lineID }) else { return }
        let question = chat[idx].sourceQuestion
        guard !question.isEmpty else { return }
        guard !chat[idx].aiLoading else { return }

        chat[idx].aiLoading = true
        Task {
            let answer = await runAI(question: question)
            if let i = chat.firstIndex(where: { $0.id == lineID }) {
                chat[i].aiLoading = false
            }
            // 同样的话不重复堆叠
            if let last = chat.last, last.text == answer, last.mode == "llm" { return }
            var line = ChatLine(role: "assistant", text: answer, mode: "llm")
            line.images = imagesFor(question: question, answer: answer)
            chat.append(line)
            let found = skusMentioned(in: answer)
            if !found.isEmpty {
                lastListSkus = found
                lastCodes = found
            }
        }
    }

    /// 走 AI 拿答案（带工具查库 + 严格校验）
    private func runAI(question: String) async -> String {
        let context = buildContext(for: question)
        do {
            let (reply, evidence) = try await DeepSeekClient.askWithTools(
                question: question,
                key: settings.deepSeekKey,
                history: chat,
                base: settings.apiBase,
                model: settings.apiModel,
                products: products,
                restock: restock
            )
            var finalReply = reply
            var finalEvidence = evidence + "\n" + context

            if !Rules.strictCheck(answer: finalReply, evidence: finalEvidence, question: question) {
                let retry = try? await DeepSeekClient.askWithTools(
                    question: question,
                    key: settings.deepSeekKey,
                    history: chat,
                    base: settings.apiBase,
                    model: settings.apiModel,
                    products: products,
                    restock: restock,
                    extraInstruction: "上一次回答里出现了表格数据里没有的数字或编号。这一次只能原样照抄工具返回值，不得推算、不得四舍五入、不得编造。"
                )
                if let retry, Rules.strictCheck(answer: retry.text,
                                                evidence: retry.evidence + "\n" + context,
                                                question: question) {
                    finalReply = retry.text
                    finalEvidence = retry.evidence + "\n" + context
                }
            }

            // 不再整段拦截：对不上的地方打 ⚠️ 标出来，其余照常显示
            let (marked, issues) = Rules.markUnverified(answer: finalReply,
                                                        evidence: finalEvidence,
                                                        question: question)
            if issues.isEmpty {
                return greet(marked)
            }
            var out = greet(marked)
            out += "\n\n⚠️ 上面标 ⚠️ 的 \(issues.count) 处（\(issues.prefix(5).joined(separator: "、"))）"
            out += "在表格里找不到，可能是 AI 推算的，请核对后再用。"
            return out
        } catch {
            if settings.deepSeekKey.trimmingCharacters(in: .whitespaces).isEmpty {
                return "主人，问 AI 需要先填 DeepSeek API Key（设置 → AI 对话）。"
            }
            return "主人，AI 这次没连上：\(error.localizedDescription)\n本地结果保留在上面。"
        }
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

    /// 数量文字 → 数字。支持 80*7、99*3+16、16+80×2、97 128 这类写法
    private func parseNumber(_ text: String?) -> Double? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        var s = raw
        s = s.replacingOccurrences(of: "，", with: "+")
        s = s.replacingOccurrences(of: ",", with: "+")
        s = s.replacingOccurrences(of: "、", with: "+")
        s = s.replacingOccurrences(of: "；", with: "+")
        s = s.replacingOccurrences(of: ";", with: "+")
        s = s.replacingOccurrences(of: "＋", with: "+")
        s = s.replacingOccurrences(of: "×", with: "*")
        s = s.replacingOccurrences(of: "✕", with: "*")
        s = s.replacingOccurrences(of: "x", with: "*")
        s = s.replacingOccurrences(of: "X", with: "*")
        s = s.replacingOccurrences(of: "＊", with: "*")

        // 数字之间的空格当分隔（97 128 → 97+128）
        s = s.replacingOccurrences(of: "(\\d)\\s+(?=\\d)",
                                  with: "$1+", options: .regularExpression)
        // 去掉其余空格和制表
        s = s.replacingOccurrences(of: " ", with: "")
        s = s.replacingOccurrences(of: "\t", with: "")
        s = s.replacingOccurrences(of: "＋", with: "+")

        // 去掉末尾多余的加号
        while s.hasSuffix("+") { s.removeLast() }
        guard !s.isEmpty else { return nil }

        // 先整体当数字
        if let v = Double(s) { return v }

        // 按 + 拆项，每项可能是 a*b*c
        let terms = s.split(separator: "+", omittingEmptySubsequences: true)
        guard !terms.isEmpty else { return nil }
        var total: Double = 0
        for term in terms {
            let factors = term.split(separator: "*", omittingEmptySubsequences: true)
            guard !factors.isEmpty else { return nil }
            var product: Double = 1
            for f in factors {
                guard let v = Double(f) else { return nil }
                product *= v
            }
            total += product
        }
        return total
    }

    /// 明显不是款号的行（表里误写的说明文字）
    private func isNotASku(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        let junk = ["没货", "无货", "散剪", "剪", "加工费", "加工", "条码", "订货", "定做",
                    "来布", "费用", "合计", "小计", "备注", "暂无", "售完", "缺货", "底布加工"]
        for w in junk where t == w || (t.count <= 4 && t.contains(w)) { return true }
        return false
    }

    private func normalizeQty(_ text: String?) -> Double? {
        guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let v = parseNumber(raw) { return v }
        if raw.contains("没货") || raw.contains("无货") { return 0 }
        return nil
    }
}
