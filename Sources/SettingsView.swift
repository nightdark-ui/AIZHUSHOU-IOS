import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var draft = AppSettings()

    @State private var openInventory = false
    @State private var openPrice = false
    @State private var openAI = false
    @State private var showFolderPicker = false
    @State private var showTestAlert = false
    @State private var openThreshold = false
    @State private var thresholdMessage = ""
    @FocusState private var thresholdFocused: Bool
    @State private var backupURL: URL?
    @State private var showShare = false
    @State private var showImport = false
    @State private var rebuildNote = ""

    var body: some View {
        NavigationStack {
            Form {
                // 库存表
                DisclosureGroup(isExpanded: $openInventory) {
                    SecureField("AirScript 令牌", text: $draft.inventoryToken)
                    TextField("文件 ID", text: $draft.inventoryFileId)
                    TextField("脚本 ID", text: $draft.inventoryScriptId)
                } label: {
                    label("库存表", detail: draft.inventoryToken.isEmpty ? "未填令牌" : "已填")
                }

                // 价格表
                DisclosureGroup(isExpanded: $openPrice) {
                    SecureField("AirScript 令牌", text: $draft.priceToken)
                    TextField("文件 ID", text: $draft.priceFileId)
                    TextField("脚本 ID", text: $draft.priceScriptId)
                    Text("价格表只在打开 App 和「保存并同步」时拉取。")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                } label: {
                    label("价格表", detail: draft.priceToken.isEmpty ? "未填令牌" : "已填")
                }

                // AI
                DisclosureGroup(isExpanded: $openAI) {
                    SecureField("DeepSeek API Key", text: $draft.deepSeekKey)
                    TextField("接口地址", text: $draft.apiBase)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("模型名称", text: $draft.apiModel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        store.settings = draft
                        Task { await store.testModel() }
                    } label: {
                        Text("测试连接")
                    }
                    if !store.modelStatus.isEmpty {
                        Text(store.modelStatus)
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                } label: {
                    label("AI 对话", detail: draft.deepSeekKey.isEmpty ? "未填 Key" : "已填")
                }

                Section {
                    HStack {
                        Text("图库文件夹")
                        Spacer()
                        Text(store.library.hasFolder
                             ? (store.library.folderName.isEmpty ? "已选择" : store.library.folderName)
                             : "未选择")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                    Button {
                        showFolderPicker = true
                    } label: {
                        Text(store.library.hasFolder ? "重新选择文件夹" : "选择图库文件夹")
                    }
                    if store.library.hasFolder {
                        Button {
                            rebuildNote = "正在重建索引…"
                            Task {
                                await store.library.rebuild()
                                rebuildNote = store.library.errorText.isEmpty
                                    ? "索引完成：\(store.library.fileCount) 张图\(store.library.mapped ? "（已读映射）" : "")"
                                    : store.library.errorText
                            }
                        } label: {
                            HStack {
                                Text("重建索引（\(store.library.fileCount) 张图\(store.library.mapped ? " · 已读映射" : "")）")
                                if store.library.building {
                                    Spacer()
                                    ProgressView().scaleEffect(0.8)
                                }
                            }
                        }
                        .disabled(store.library.building)

                        if !rebuildNote.isEmpty {
                            Text(rebuildNote)
                                .font(.caption)
                                .foregroundStyle(rebuildNote.hasPrefix("索引完成") ? Theme.ok : Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !store.library.errorText.isEmpty {
                        Text(store.library.errorText)
                            .font(.caption2)
                            .foregroundStyle(Theme.danger)
                    }
                } header: {
                    Text("图片图库")
                } footer: {
                    Text("选一个放着款式图片的文件夹（文件名用编号，比如 2002.jpg）。问「2002 图片」就会带图。")
                        .foregroundStyle(Theme.muted)
                }

                DisclosureGroup(isExpanded: $openThreshold) {
                    HStack {
                        Text("低于这个数就提醒")
                            .font(.system(size: 14))
                        Spacer()
                        TextField("300", value: $draft.threshold, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($thresholdFocused)
                            .frame(width: 90)
                    }

                    HStack {
                        Spacer()
                        Button {
                            store.settings = draft
                            store.applyDefaultThreshold()
                            thresholdMessage = store.statusText
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            thresholdFocused = false
                        } label: {
                            Text("应用").pill(blue: true)
                        }
                        .buttonStyle(.plain)
                    }

                    if !thresholdMessage.isEmpty {
                        Text(thresholdMessage)
                            .font(.caption)
                            .foregroundStyle(Theme.ok)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        Notifier.requestPermission()
                        Notifier.test()
                        showTestAlert = true
                    } label: {
                        Text("测试通知（5 秒后）")
                    }
                } label: {
                    HStack {
                        Text("补货提醒线")
                        Spacer()
                        Text("\(Int(store.settings.threshold))")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }

                Section {
                    Button {
                        store.settings = draft
                        Task { await store.saveAndSync() }
                    } label: {
                        Text("保存并同步（库存 + 价格）").frame(maxWidth: .infinity)
                    }
                }

                Section {
                    Button {
                        if let url = store.exportBackup() {
                            backupURL = url
                            showShare = true
                        }
                    } label: {
                        Text("导出备份（存到「文件」App）")
                    }

                    Button {
                        showImport = true
                    } label: {
                        Text("从备份恢复")
                    }

                    if !store.backupMessage.isEmpty {
                        Text(store.backupMessage)
                            .font(.caption)
                            .foregroundStyle(store.backupMessage.hasPrefix("备份已生成")
                                             || store.backupMessage.hasPrefix("恢复成功")
                                             ? Theme.ok : Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("备份与恢复")
                } footer: {
                    Text("备份只含：15 项设置、补货确认记录、最后一次库存和价格。换证书或删了重装后，从这里恢复；库存明细会以备份里那份为准，之后同步一次即可更新。")
                        .foregroundStyle(Theme.muted)
                }

                Section {
                    HStack {
                        Text("证书剩余")
                        Spacer()
                        Text(CertStatus.text)
                            .font(.caption)
                            .foregroundStyle(CertStatus.level == 2 ? Theme.danger
                                             : (CertStatus.level == 1 ? Theme.warn : Theme.muted))
                    }
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(AppInfo.versionText)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                } header: {
                    Text("运行状态")
                } footer: {
                    Text(certFooter)
                        .foregroundStyle(CertStatus.level == 2 ? Theme.danger
                                         : (CertStatus.level == 1 ? Theme.warn : Theme.muted))
                }

                Section("状态") {
                    Text(store.statusText)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { thresholdFocused = false }
                }
            }
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.library.setFolder(url)
                }
            }
            .alert("通知已发送", isPresented: $showTestAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请等 5 秒。如果 5 秒后没看到通知，说明系统通知权限被关掉了，去「设置 → 通知 → AI小助手」打开。")
            }
            .sheet(isPresented: $showShare) {
                if let url = backupURL {
                    ShareLink(item: url) {
                        Label("保存备份文件", systemImage: "square.and.arrow.up")
                    }
                    .padding(30)
                    .presentationDetents([.height(180)])
                }
            }
            .fileImporter(isPresented: $showImport,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.importBackup(from: url)
                }
            }
            .onAppear { draft = store.settings }
        }
    }

    /// 证书提示文案
    private var certFooter: String {
        switch CertStatus.level {
        case 2:
            return "证书快到期了：连电脑用签名工具重新签一次（数据不会丢）。"
        case 1:
            return "证书 3 天内到期，找个空闲时间重签一次。"
        default:
            return "免费签名 7 天有效；重签后这里会重新计时。"
        }
    }

    private func label(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }
}
