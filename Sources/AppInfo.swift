import Foundation

/// 版本信息（设置页显示，方便反馈问题时核对）
enum AppInfo {

    /// 显示用：1.9.0（203）
    static var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v)（\(b)）"
    }

    /// 纯版本号，比如 1.9.0
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// 构建号，比如 203
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// 打包时写进二进制的时间（用于确认装的是不是最新包）
    static var buildTime: String {
        let date = Bundle.main.object(forInfoDictionaryKey: "BuildTime") as? String
        return date ?? "—"
    }
}
