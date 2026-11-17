import SwiftUI

/// 单项数量异常的明细（比如表格里「97 128」被存成 97128）
struct QtyIssuesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("单条数量不该超过 \(Int(QtyCheck.singleLimit))。超过的多半是两个数字粘在一起（表格里写「97 128」，WPS 会存成 97128），建议去表格里改成「97+128」。")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }

                Section {
                    ForEach(store.qtyIssues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(issue.sku)
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.semibold)
                                Spacer()
                                Text(issue.value == issue.value.rounded()
                                     ? "\(Int(issue.value))"
                                     : "\(Int(issue.value))")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(Theme.danger)
                            }
                            Text(issue.hint)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                } header: {
                    Text("共 \(store.qtyIssues.count) 个款")
                }
            }
            .navigationTitle("数量异常")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
