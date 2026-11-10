import SwiftUI

/// 补货历史（和电脑版一致：按日期倒序，显示编号 / 确认时间 / 当时剩余）
struct HistoryView: View {
    @EnvironmentObject private var store: AppStore

    private var grouped: [(date: String, items: [HistoryItem])] {
        let dict = Dictionary(grouping: store.history) { $0.ackDate }
        return dict.keys.sorted(by: >).map { ($0, dict[$0] ?? []) }
    }

    var body: some View {
        Group {
            if store.history.isEmpty {
                ContentUnavailableView(
                    "还没有历史",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(store.historyLoading ? "正在加载…" : "下拉刷新试试")
                )
            } else {
                List {
                    ForEach(grouped, id: \.date) { group in
                        Section(header: Text("\(group.date)  ·  \(group.items.count) 条")) {
                            ForEach(group.items) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.sku)
                                            .font(.system(.body, design: .monospaced))
                                            .fontWeight(.semibold)
                                        Text(item.timeText)
                                            .font(.caption2)
                                            .foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(item.qty.map { "剩 \(Int($0))" } ?? "—")
                                            .font(.subheadline)
                                            .foregroundStyle(Theme.ok)
                                        if let p = item.priceText, !p.isEmpty {
                                            Text("¥\(p)")
                                                .font(.caption)
                                                .foregroundStyle(Theme.muted)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .background(Theme.bg)
            }
        }
        .refreshable { await store.loadHistory() }
        .task {
            if store.history.isEmpty { await store.loadHistory() }
        }
    }
}
