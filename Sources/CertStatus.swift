import Foundation

/// 证书倒计时（免费签名 7 天）
///
/// 判断依据：App 包目录的创建时间 = 这次安装/覆盖签名的时间。
/// 覆盖安装（同一 Apple ID 重签）会刷新这个时间，所以续签后倒计时会重新从 7 天开始。
enum CertStatus {

    /// 免费签名有效期（天）
    static let lifetimeDays = 7

    /// 这次安装的时间
    static var installedAt: Date? {
        // ① 优先用 App 包目录的创建时间（覆盖安装会更新）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath),
           let created = attrs[.creationDate] as? Date {
            return created
        }
        // ② 退路：首次启动时间
        let key = "aizhushou.firstLaunch"
        if let saved = UserDefaults.standard.object(forKey: key) as? Date {
            return saved
        }
        let now = Date()
        UserDefaults.standard.set(now, forKey: key)
        return now
    }

    /// 到期时间
    static var expireAt: Date? {
        guard let start = installedAt else { return nil }
        return Calendar.current.date(byAdding: .day, value: lifetimeDays, to: start)
    }

    /// 剩余天数（向上取整；已过期返回 0 或负数）
    static var daysLeft: Int? {
        guard let expire = expireAt else { return nil }
        let seconds = expire.timeIntervalSinceNow
        if seconds <= 0 {
            return Int(floor(seconds / 86400))
        }
        return Int(ceil(seconds / 86400))
    }

    /// 设置页显示的一行文字
    static var text: String {
        guard let days = daysLeft, let expire = expireAt else { return "未知" }
        let df = DateFormatter()
        df.dateFormat = "MM-dd"
        let dateText = df.string(from: expire)
        if days <= 0 {
            return "已过期，请重新签名"
        }
        if days == 1 {
            return "剩 1 天（\(dateText) 到期）"
        }
        return "剩 \(days) 天（\(dateText) 到期）"
    }

    /// 紧急程度：0 正常 / 1 注意 / 2 紧急或过期
    static var level: Int {
        guard let days = daysLeft else { return 0 }
        if days <= 1 { return 2 }
        if days <= 3 { return 1 }
        return 0
    }
}
