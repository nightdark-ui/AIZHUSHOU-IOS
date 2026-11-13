import SwiftUI

struct InventoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var keyword = ""
    @State private var editingSKU: String?
    @State private var editingValue = ""
    @State private var showEditor = false

    private var filtered: [Product] {
        let k = keyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return store.products }
        return store.products.filter { $0.sku.localizedCaseInsensitiveContains(k) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { p in
                row(p)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            editingSKU = p.sku
                            editingValue = p.minQty.map { String(Int($0)) } ?? ""
                            showEditor = true
                        } label: {
                            Label("提醒线", systemImage: "slider.horizontal.3")
                        }
                        .tint(.orange)

                        if p.minQty != nil {
                            Button(role: .destructive) {
                                store.setMinQty(sku: p.sku, value: nil)
                            } label: {
                                Label("恢复默认", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
            }
            .listStyle(.plain)
            .searchable(text: $keyword, prompt: "搜编号")
            .safeAreaInset(edge: .top) {
                if store.lastSyncFailed {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 11))
                        Text(store.syncWarning.isEmpty
                             ? "没连上，显示的是 \(store.lastSyncText) 的旧数据"
                             : store.syncWarning)
                            .font(.system(size: 11))
                            .lineLimit(2)
                        Spacer()
                        Button {
                            Task { await store.sync(prices: false) }
                        } label: {
                            Text("重试").font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(Theme.warn)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.warnSoft)
                }
            }
            .refreshable { await store.sync(prices: false) }
            .navigationTitle("库存")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.syncing {
                        HStack(spacing: 4) {
                            Text("同步\(store.syncStage)…")
                            if let sec = store.syncElapsed, sec >= 5 { Text("\(sec)s") }
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    } else {
                        Text(store.lastSyncText)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.sync(prices: false) }
                    } label: {
                        if store.syncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(store.syncing)
                }
            }
            .overlay {
                if store.products.isEmpty && !store.syncing {
                    ContentUnavailableView(
                        "还没有数据",
                        systemImage: "shippingbox",
                        description: Text("先去「设置」填 WPS 令牌，然后下拉刷新")
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(store.statusText)
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
            .alert("设置提醒线", isPresented: $showEditor) {
                TextField("默认 \(Int(store.settings.threshold))", text: $editingValue)
                    .keyboardType(.numberPad)
                Button("保存") {
                    let v = Double(editingValue.trimmingCharacters(in: .whitespaces))
                    if let sku = editingSKU {
                        store.setMinQty(sku: sku, value: v)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("低于这个数量就算「需要补货」。留空则用默认 \(Int(store.settings.threshold))。")
            }
        }
    }

    private func row(_ p: Product) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.sku)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                    if let m = p.minQty {
                        Text("线\(Int(m))")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.warnSoft)
                            .foregroundStyle(Theme.warn)
                            .clipShape(Capsule())
                    }
                }
                if let t = p.qtyText, !t.isEmpty {
                    Text(t)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(qtyText(p))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(qtyColor(p))
                if let price = p.priceText, !price.isEmpty {
                    Text("¥\(price)")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func qtyText(_ p: Product) -> String {
        if let q = p.qty {
            return q == 0 ? "没货" : "\(Int(q))"
        }
        if let t = p.qtyText, !t.isEmpty { return t }
        return "—"
    }

    private func qtyColor(_ p: Product) -> Color {
        if let q = p.qty {
            if q <= 0 { return Theme.danger }
            if q < (p.minQty ?? store.settings.threshold) { return Theme.warn }
            return .primary
        }
        if let t = p.qtyText, !t.isEmpty { return Theme.warn }
        return .secondary
    }
}
