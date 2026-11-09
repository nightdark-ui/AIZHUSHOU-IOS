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
}
