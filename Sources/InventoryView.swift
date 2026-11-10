import SwiftUI

struct InventoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var keyword = ""

    private var filtered: [Product] {
        let k = keyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return store.products }
        return store.products.filter {
            $0.sku.localizedCaseInsensitiveContains(k)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { p in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.sku)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.semibold)
                        if let t = p.qtyText, !t.isEmpty {
                            Text(t)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
            .searchable(text: $keyword, prompt: "搜编号")
            .refreshable {
                await store.sync()
            }
            .navigationTitle("库存")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(store.lastSyncText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.sync() }
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
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    private func qtyText(_ p: Product) -> String {
        if let q = p.qty {
            return q == 0 ? "没货" : "\(Int(q))"
        }
        if let t = p.qtyText, !t.isEmpty {
            return t          // 算不出数字就原样显示表格里写的
        }
        return "—"
    }

    private func qtyColor(_ p: Product) -> Color {
        if let q = p.qty {
            if q <= 0 { return .red }
            if q < store.settings.threshold { return .orange }
            return .primary
        }
        if let t = p.qtyText, !t.isEmpty { return .orange }
        return .secondary
    }
}
