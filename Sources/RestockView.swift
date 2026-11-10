import SwiftUI

struct RestockView: View {
    @EnvironmentObject private var store: AppStore
    @State private var tab = 0
    @State private var showRules = false
    @State private var selecting = false
    @State private var selected = Set<String>()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("待补货 \(store.restock.count)").tag(0)
                    Text("补货历史").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                if tab == 0 {
                    pending
                } else {
                    HistoryView()
                }
            }
            .background(Theme.bg)
            .navigationTitle("补货")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if tab == 0 && !store.restock.isEmpty {
                        Button {
                            selecting.toggle()
                            if !selecting { selected.removeAll() }
                        } label: {
                            Text(selecting ? "完成" : "选择")
                                .pill(active: selecting)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showRules.toggle()
                    } label: {
                        Text("规则").pill()
                    }
                }
            }
            .sheet(isPresented: $showRules) {
                rulesSheet
            }
            .onChange(of: tab) { _, newValue in
                if newValue == 1, store.history.isEmpty {
                    Task { await store.loadHistory() }
                }
                if newValue != 0 {
                    selecting = false
                    selected.removeAll()
                }
            }
        }
    }

    private var rulesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    rule(title: "什么算需要补货", body: """
                    两个条件同时满足才会进清单：
                    ① 今天数量比「上一次快照」少了
                    ② 今天的数量低于提醒线
                    数量没变小、或者还在提醒线以上，都不会提醒。
                    """)
                    rule(title: "提醒线", body: """
                    默认 300 码。可以给单个款单独设：
                    库存页 → 左滑那一行 →「提醒线」→ 输入数字。
                    """)
                    rule(title: "怎么确认", body: """
                    点每条的「确认」，或者右上角「选择」勾多个一起确认。
                    确认后这条会消失，并同步给电脑版。
                    """)
                    rule(title: "数据从哪来", body: """
                    每次刷新库存时从 WPS 表格读取当天数量，
                    并在本机记一份快照（保留最近 60 天）。
                    """)
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("补货规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("知道了") { showRules = false }
                }
            }
        }
    }

    private func rule(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(body)
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private var pending: some View {
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
                ForEach(store.restock) { item in
                    row(item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selecting { toggle(item.sku) }
                        }
                }
            }
            .listStyle(.plain)
            .background(Theme.bg)
            .refreshable { await store.refreshRestock() }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    HStack(spacing: 14) {
                        Button {
                            if selected.count == store.restock.count {
                                selected.removeAll()
                            } else {
                                selected = Set(store.restock.map { $0.sku })
                            }
                        } label: {
                            Text(selected.count == store.restock.count ? "取消全选" : "全选")
                                .pill(active: !selected.isEmpty)
                        }

                        Spacer()

                        Button {
                            let items = store.restock.filter { selected.contains($0.sku) }
                            store.ackMany(items)
                            selecting = false
                            selected.removeAll()
                        } label: {
                            Text("确认 \(selected.count) 个")
                                .pill(active: !selected.isEmpty,
                                      filled: !selected.isEmpty)
                        }
                        .disabled(selected.isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.panel)
                    .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
                }
            }
        }
    }

    private func toggle(_ sku: String) {
        if selected.contains(sku) {
            selected.remove(sku)
        } else {
            selected.insert(sku)
        }
    }

    private func row(_ item: RestockItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if selecting {
                Image(systemName: selected.contains(item.sku)
                      ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected.contains(item.sku) ? Theme.ok : Theme.muted)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.sku)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                    Spacer()
                    Text(item.levelLabel)
                        .font(.caption2)
                        .foregroundStyle(item.level == "danger" ? Theme.danger : Theme.warn)
                }
                HStack {
                    Text("原 \(Int(item.prevQty ?? 0)) → 现 \(Int(item.qty ?? 0))")
                        .font(.caption)
                        .foregroundStyle(Theme.warn)
                    Spacer()
                    Text("少了 \(Int(abs(item.change)))")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle((item.qty ?? 0) <= 0 ? Theme.danger : Theme.text)
                    if !selecting {
                        Button {
                            store.ack(item)
                        } label: {
                            Text("确认")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.ok)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Theme.okSoft)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(Theme.ok.opacity(0.35), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 6)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button {
                store.ack(item)
            } label: {
                Label("确认", systemImage: "checkmark")
            }
        }
    }
}
