import Foundation

/// 证书倒计时（免费签名 7 天）
///
/// 判断顺序：
///   ① 读 App 内嵌的签名描述文件（embedded.mobileprovision）里的 ExpirationDate —— 最准
///   ② 读不到就用「本机首次启动时间 + 7 天」估算
enum CertStatus {

    /// 免费签名有效期（天），仅用于估算
    static let lifetimeDays = 7

    /// 从描述文件里取真实到期时间
    static var profileExpireAt: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }

        // 描述文件是 CMS 签名包，里面夹着一段 XML plist，直接截出来解析
        guard let start = data.range(of: Data("<?xml".utf8)) else { return nil }
        guard let end = data.range(of: Data("</plist>".utf8),
                                   options: [],
                                   in: start.lowerBound..<data.count) else { return nil }

        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let obj = try? PropertyListSerialization.propertyList(from: plistData,
                                                                   options: [],
                                                                   format: nil),
              let dict = obj as? [String: Any] else { return nil }

        if let exp = dict["ExpirationDate"] as? Date { return exp }
        // 有的版本放在 Entitlements 外层，兜底再找一次
        if let exp = dict["ExpirationDate"] as? String {
            let f = ISO8601DateFormatter()
            return f.date(from: exp)
        }
        return nil
    }

    /// 首次启动时间（读不到描述文件时用来估算）
    static var firstLaunchAt: Date {
        let key = "aizhushou.firstLaunch"
        if let saved = UserDefaults.standard.object(forKey: key) as? Date { return saved }
        let now = Date()
        UserDefaults.standard.set(now, forKey: key)
        return now
    }

    /// 到期时间
    static var expireAt: Date? {
        if let real = profileExpireAt { return real }
        return Calendar.current.date(byAdding: .day, value: lifetimeDays, to: firstLaunchAt)
    }

    /// 是否用的是真实描述文件时间（false = 估算）
    static var isEstimated: Bool { profileExpireAt == nil }

    /// 剩余天数（向上取整；已过期返回 ≤0）
    static var daysLeft: Int? {
        guard let expire = expireAt else { return nil }
        let seconds = expire.timeIntervalSinceNow
        if seconds <= 0 { return Int(floor(seconds / 86400)) }
        return Int(ceil(seconds / 86400))
    }

    /// 设置页显示的文字
    static var text: String {
        guard let days = daysLeft, let expire = expireAt else { return "未知" }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        let dateText = df.string(from: expire)
        let mark = isEstimated ? "（估算）" : ""

        if days <= 0 {
            return "已过期（\(dateText)）\(mark)"
        }
        if days == 1 {
            return "剩 1 天（\(dateText) 到期）\(mark)"
        }
        return "剩 \(days) 天（\(dateText) 到期）\(mark)"
    }

    /// 紧急程度：0 正常 / 1 注意 / 2 紧急或过期
    static var level: Int {
        guard let days = daysLeft else { return 0 }
        if days <= 1 { return 2 }
        if days <= 3 { return 1 }
        return 0
    }
}
