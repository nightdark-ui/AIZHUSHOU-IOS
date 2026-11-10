import SwiftUI

/// 补货历史（和电脑版一致：按日期倒序，显示编号 / 确认时间 / 当时剩余）
struct HistoryView: View {
    @EnvironmentObject private var store: AppStore

    private var grouped: [(date: String, items: [HistoryItem])] {
        let dict = Dictionary(grouping: store.history) { $0.ackDate }
        return dict.keys.sorted(by: >).map { ($0, dict[$0] ?? []) }
    }

    private func changeText(_ item: HistoryItem) -> String {
        let now = Int(item.qty ?? 0)
        guard let prev = item.prevQty else {
            return "补货后剩 \(now)"
        }
        let diff = now - Int(prev)
        return "原 \(Int(prev)) 变成今天 \(now)（\(diff)）；当前 \(now)"
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
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.sku)
                                            .font(.system(.body, design: .monospaced))
                                            .fontWeight(.semibold)
                                        Spacer()
                                        Text(item.timeText)
                                            .font(.caption2)
                                            .foregroundStyle(Theme.muted)
                                    }
                                    Text(changeText(item))
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
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
