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

    /// 每次刷新库存发现补货就提醒（5 分钟内不重复弹）
    static func notifyRestockIfNeeded(count: Int) {
        guard count > 0 else { return }

        let key = "aizhushou.lastNotify"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: key)
        if last > 0, now - last < 300 { return }
        UserDefaults.standard.set(now, forKey: key)

        let content = UNMutableNotificationContent()
        content.title = "有 \(count) 个款需要补货"
        content.body = "打开 AI小助手看看补货清单。"
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
