import SwiftUI

struct RestockView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Group {
                if store.restock.isEmpty {
                    ContentUnavailableView(
                        "现在没有要补的",
                        systemImage: "checkmark.circle",
                        description: Text(store.products.isEmpty
                                          ? "先去「设置」同步一次数据"
                                          : "库存没有下降，或者都还在提醒线以上")
                    )
                } else {
                    List {
                        Section {
                            ForEach(store.restock) { item in
                                row(item)
                            }
                        } footer: {
                            Text("规则：库存比上次减少，且低于提醒线 \(Int(store.settings.threshold))")
                        }
                    }
                    .listStyle(.plain)
                    .background(Theme.bg)
                }
            }
            .navigationTitle("补货")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(store.restock.count) 个").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .refreshable { await store.refreshRestock() }
        }
    }

    private func row(_ item: RestockItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.sku)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                Spacer()
                Text(item.levelLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(item.level == "danger" ? Theme.dangerSoft : Theme.warnSoft)
                    .foregroundStyle(item.level == "danger" ? Theme.danger : Theme.warn)
                    .clipShape(Capsule())
            }
            HStack {
                Text("少了 \(Int(abs(item.change)))")
                    .font(.caption)
                    .foregroundStyle(Theme.warn)
                Spacer()
                Text("剩 \(Int(item.qty ?? 0))")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle((item.qty ?? 0) <= 0 ? Theme.danger : Theme.text)
            }
            Text(item.reason)
                .font(.caption2)
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.ack(item)
            } label: {
                Label("已补货", systemImage: "checkmark")
            }
        }
    }
}
