import Foundation

/// 一个款（编号 + 价格 + 库存）
struct Product: Codable, Identifiable, Hashable {
    var sku: String
    var name: String?
    var priceText: String?
    var price: Double?
    var qty: Double?
    var qtyText: String?
    var minQty: Double?

    var id: String { sku }
}

/// 补货清单里的一条
struct RestockItem: Codable, Identifiable, Hashable {
    var sku: String
    var level: String          // danger / warn / unknown
    var qty: Double?
    var qtyText: String?
    var prevQty: Double?
    var prevDate: String
    var change: Double
    var reason: String
    var openedDay: String

    var id: String { sku }

    var levelLabel: String {
        switch level {
        case "danger": return "已无货"
        case "warn": return "减少"
        default: return "需人工看"
        }
    }
}

/// 一条聊天记录
struct ChatLine: Identifiable, Equatable {
    let id = UUID()
    var role: String           // user / assistant
    var text: String
    var mode: String = ""      // rule / llm
}

/// App 设置，存在 UserDefaults 里
struct AppSettings: Codable {
    var inventoryToken: String = ""
    var inventoryFileId: String = "567747105536"
    var inventoryScriptId: String = "V2-18eIGJJpwSUCRs5eWH7uCc"

    var priceToken: String = ""
    var priceFileId: String = "569772200725"
    var priceScriptId: String = "V2-31EPknBFaN3hr379C0HCe9"

    var deepSeekKey: String = ""
    var threshold: Double = 300

    // 和电脑版双向同步
    var pcBaseURL: String = ""
    var syncKey: String = ""
}
