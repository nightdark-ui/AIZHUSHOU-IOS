import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 启动瞬间的窗口底色，避免闪黑
        let bg = UIColor.white
        UIWindow.appearance().backgroundColor = bg
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        for w in application.windows {
            w.backgroundColor = .white
        }
    }
}

@main
struct AIZhushouApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .background(Color.white.ignoresSafeArea())
        }
    }
}
