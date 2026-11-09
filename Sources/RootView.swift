import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            InventoryView()
                .tabItem { Label("库存", systemImage: "shippingbox") }
                .tag(0)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(1)
        }
        .tint(.blue)
    }
}
