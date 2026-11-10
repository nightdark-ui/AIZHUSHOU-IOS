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
            if phase == .active { store.autoSyncIfNeeded() }
        }
    }
}
