import SwiftUI

struct RestockView: View {
    @EnvironmentObject private var store: AppStore
    @State private var tab = 0
    @State private var showRules = false

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showRules.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
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
                    设过之后行首会有橙色「线xxx」标签。
                    """)

                    rule(title: "确认做完了", body: """
                    补货页 → 左滑那一条 →「已补货」。
                    确认后这条会消失，并且同步给电脑版；
                    电脑上确认的，也会同步回手机。
                    """)

                    rule(title: "数据从哪来", body: """
                    每次刷新库存时，从 WPS 表格读取当天的数量，
                    并在本机记一份快照（只留最近 60 天）。
                    所以补货判断完全在手机上算，断网也能看。
                    """)

                    rule(title: "什么时候提醒", body: """
                    每次刷新库存发现有待补的款，就会弹一次通知
                    （5 分钟内不重复）。补货清空后不再提醒。
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
                Section {
                    ForEach(store.restock) { item in
                        row(item)
                    }
                }
            }
            .listStyle(.plain)
            .background(Theme.bg)
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
            Button {
                store.ack(item)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("已补货")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ok)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.okSoft)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
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
