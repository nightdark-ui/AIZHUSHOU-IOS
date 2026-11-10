import Foundation
import UserNotifications

/// 本地通知：有补货就每天 9 点提醒一次
enum Notifier {

    static let restockID = "aizhushou.restock.daily"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// 安排明天 9 点（如果现在还没到 9 点就今天）
    static func scheduleRestock(count: Int) {
        guard count > 0 else {
            cancelRestock()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [restockID])

        let content = UNMutableNotificationContent()
        content.title = "有 \(count) 个款需要补货"
        content.body = "打开 AI小助手看看补货清单。"
        content.sound = .default

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 9
        comps.minute = 0
        var fire = Calendar.current.date(from: comps) ?? Date()
        if fire <= Date() {
            fire = Calendar.current.date(byAdding: .day, value: 1, to: fire) ?? fire
            comps = Calendar.current.dateComponents([.year, .month, .day], from: fire)
            comps.hour = 9
            comps.minute = 0
        }

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: restockID, content: content, trigger: trigger)
        center.add(request) { _ in }
    }

    static func cancelRestock() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [restockID])
    }

    /// 测试用：5 秒后弹一条
    static func test() {
        let content = UNMutableNotificationContent()
        content.title = "AI小助手"
        content.body = "通知可以正常弹出 👍"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "aizhushou.test", content: content, trigger: trigger))
    }
}
