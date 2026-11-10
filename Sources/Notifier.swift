import Foundation
import UserNotifications

/// 前台也显示横幅
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler:
                               @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

enum Notifier {

    static let delegate = NotificationDelegate()

    static func requestPermission() {
        UNUserNotificationCenter.current().delegate = delegate
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// 只有出现「新的补货款」才提醒。
    /// 同一批货反复刷新不会再弹；确认掉一部分也不会弹。
    static func notifyRestockIfNeeded(count: Int, skus: [String] = []) {
        guard count > 0 else { return }

        let sigKey = "aizhushou.notify.skus"
        let timeKey = "aizhushou.notify.time"

        let current = Set(skus.map { $0.uppercased() })
        let lastSig = UserDefaults.standard.string(forKey: sigKey) ?? ""
        let previous = Set(lastSig.split(separator: ",").map { String($0) })

        // 一个都没新增 → 不打扰
        let fresh = current.subtracting(previous)
        guard !fresh.isEmpty else { return }

        // 最短间隔 60 秒，避免刚启动连弹
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: timeKey)
        if last > 0, now - last < 60 { return }

        UserDefaults.standard.set(current.sorted().joined(separator: ","), forKey: sigKey)
        UserDefaults.standard.set(now, forKey: timeKey)

        let content = UNMutableNotificationContent()
        content.title = "有 \(count) 个款需要补货"
        content.body = fresh.count >= count
            ? "打开 AI小助手看看补货清单。"
            : "新增 \(fresh.count) 个：\(fresh.sorted().prefix(5).joined(separator: "、"))"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "aizhushou.restock.now",
                                       content: content, trigger: trigger))
    }

    /// 兼容旧调用点
    static func scheduleRestock(count: Int) {
        notifyRestockIfNeeded(count: count)
    }

    static func cancelRestock() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["aizhushou.restock.now"])
    }

    /// 测试用：5 秒后弹一条
    static func test() {
        let content = UNMutableNotificationContent()
        content.title = "AI小助手"
        content.body = "通知可以正常弹出 👍"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "aizhushou.test",
                                       content: content, trigger: trigger))
    }
}
