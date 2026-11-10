import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ChatView()
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                .tag(0)

            InventoryView()
                .tabItem { Label("库存", systemImage: "shippingbox") }
                .tag(1)

            RestockView()
                .tabItem { Label("补货", systemImage: "exclamationmark.triangle") }
                .badge(store.restock.count)
                .tag(2)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .tint(.blue)
        .task { store.launchSync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.autoSyncIfNeeded()
                Task { _ = await store.syncAcks() }
            }
        }
        .task {
            // 前台每 60 秒检查一次：补推确认 + 库存超过 5 分钟就自动拉
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard scenePhase == .active else { continue }
                if store.pendingAcks > 0 {
                    _ = await store.syncAcks()
                }
                store.periodicSyncIfNeeded()
            }
        }
    }
}
