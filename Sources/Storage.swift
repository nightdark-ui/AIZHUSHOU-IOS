import Foundation

/// 本地存储：商品、每日快照、已确认记录（都用 JSON 文件，简单可靠）
struct Storage {

    private static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func url(_ name: String) -> URL {
        dir.appendingPathComponent(name)
    }

    // MARK: - 商品

    static func loadProducts() -> [Product] {
        guard let data = try? Data(contentsOf: url("products.json")),
              let list = try? JSONDecoder().decode([Product].self, from: data) else { return [] }
        return list
    }

    static func saveProducts(_ list: [Product]) {
        let enc = JSONEncoder()
        if let data = try? enc.encode(list) {
            try? data.write(to: url("products.json"), options: .atomic)
        }
    }

    // MARK: - 每日快照  ["2026-11-10": ["2002": 577.0, ...]]

    static func loadSnapshots() -> [String: [String: Double]] {
        guard let data = try? Data(contentsOf: url("snapshots.json")),
              let dict = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else {
            return [:]
        }
        return dict
    }

    static func saveSnapshots(_ dict: [String: [String: Double]]) {
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: url("snapshots.json"), options: .atomic)
        }
    }

    /// 记下今天的库存（同一天重复写会覆盖）
    static func recordSnapshot(_ products: [Product], day: String) {
        var all = loadSnapshots()
        var today: [String: Double] = [:]
        for p in products {
            if let q = p.qty { today[p.sku] = q }
        }
        guard !today.isEmpty else { return }
        all[day] = today

        // 只留最近 60 天
        if all.count > 60 {
            let sorted = all.keys.sorted()
            for old in sorted.dropLast(60) { all.removeValue(forKey: old) }
        }
        saveSnapshots(all)
    }

    /// 从电脑补一份历史快照（只在本地没有更早数据时用）
    static func importBaseline(day: String, values: [String: Double]) {
        guard !values.isEmpty else { return }
        var all = loadSnapshots()
        if let exist = all[day], !exist.isEmpty { return }
        all[day] = values
        if all.count > 60 {
            let sorted = all.keys.sorted()
            for old in sorted.dropLast(60) { all.removeValue(forKey: old) }
        }
        saveSnapshots(all)
    }

    /// 今天之前最近一天的快照
    static func previousSnapshot(before day: String) -> (date: String, values: [String: Double])? {
        let all = loadSnapshots()
        let earlier = all.keys.filter { $0 < day }.sorted()
        guard let last = earlier.last, let values = all[last] else { return nil }
        return (last, values)
    }

    // MARK: - 已确认（补货）

    /// 指纹：编号 + 上次日期 + 当时数量
    static func ackKey(sku: String, prevDate: String, qty: Double?) -> String {
        let qtyPart = qty.map { String(Int($0)) } ?? "nil"
        return "\(sku)|\(prevDate)|\(qtyPart)"
    }

    static func loadAcks() -> Set<String> {
        guard let data = try? Data(contentsOf: url("acks.json")),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    static func addAck(_ key: String) {
        var set = loadAcks()
        set.insert(key)
        if let data = try? JSONEncoder().encode(Array(set)) {
            try? data.write(to: url("acks.json"), options: .atomic)
        }
    }


    // MARK: - 已推送的确认（判断有没有没送出去的）

    static func loadPushed() -> Set<String> {
        guard let data = try? Data(contentsOf: url("pushed.json")),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    static func addPushed(_ keys: [String]) {
        var set = loadPushed()
        set.formUnion(keys)
        if let data = try? JSONEncoder().encode(Array(set)) {
            try? data.write(to: url("pushed.json"), options: .atomic)
        }
    }

    static func pendingCount() -> Int {
        let acks = loadAcks()
        let pushed = loadPushed()
        return acks.subtracting(pushed).count
    }


    // MARK: - 备份恢复

    // MARK: - 本地补货历史（确认后就记一笔，不依赖电脑）

    private static var historyURL: URL { url("ack_history.json") }

    static func loadLocalHistory() -> [HistoryItem] {
        guard let data = try? Data(contentsOf: historyURL),
              let list = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return [] }
        return list
    }

    static func appendLocalHistory(_ items: [HistoryItem]) {
        guard !items.isEmpty else { return }
        var list = loadLocalHistory()
        for item in items {
            if let idx = list.firstIndex(where: { $0.sku == item.sku && $0.ackDate == item.ackDate }) {
                list[idx] = item
            } else {
                list.append(item)
            }
        }
        // 只留最近 500 条
        if list.count > 500 { list = Array(list.suffix(500)) }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    static func restoreLocalHistory(_ list: [HistoryItem]) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    static func restoreSnapshots(_ dict: [String: [String: Double]]) {
        guard !dict.isEmpty else { return }
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: url("snapshots.json"), options: .atomic)
        }
    }

    static func restoreAcks(_ list: [String]) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url("acks.json"), options: .atomic)
        }
    }

    static func restorePushed(_ list: [String]) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url("pushed.json"), options: .atomic)
        }
    }
}
