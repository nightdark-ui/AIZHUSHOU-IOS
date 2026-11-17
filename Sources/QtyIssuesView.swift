import SwiftUI

/// 数量异常的明细（单个批次超上限 / 低于下限）
struct QtyIssuesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private var bigIssues: [QtyIssue] { store.qtyIssues.filter { $0.kind == .tooBig } }
    private var smallIssues: [QtyIssue] { store.qtyIssues.filter { $0.kind == .tooSmall } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("单个批次数量应当在 \(Int(QtyCheck.singleMin))–\(Int(QtyCheck.singleLimit)) 之间。超过上限多半是两个数字粘在一起（「97 128」被存成 97128）；低于下限多半是漏写。")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }

                if !bigIssues.isEmpty {
                    Section {
                        ForEach(bigIssues) { issue in
                            row(issue)
                        }
                    } header: {
                        Text("超过 \(Int(QtyCheck.singleLimit))（\(bigIssues.count) 个）")
                    }
                }

                if !smallIssues.isEmpty {
                    Section {
                        ForEach(smallIssues) { issue in
                            row(issue)
                        }
                    } header: {
                        Text("低于 \(Int(QtyCheck.singleMin))（\(smallIssues.count) 个）")
                    }
                }

                if store.ignoredQtyCount > 0 {
                    Section {
                        Button {
                            store.resetIgnoredQty()
                        } label: {
                            Text("恢复已忽略的 \(store.ignoredQtyCount) 条")
                        }
                    } footer: {
                        Text("忽略只影响提示；款的数量再变化时会重新出现。")
                            .foregroundStyle(Theme.muted)
                    }
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

    private func row(_ issue: QtyIssue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(issue.sku)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                Spacer()
                Text(issue.value == issue.value.rounded()
                     ? "\(Int(issue.value))"
                     : String(format: "%.1f", issue.value))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(issue.kind == .tooBig ? Theme.danger : Theme.warn)
            }
            HStack {
                Text(issue.hint)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button {
                    store.ignoreQtyIssue(issue)
                } label: {
                    Text("忽略")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.brand)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.brandSoft)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}
