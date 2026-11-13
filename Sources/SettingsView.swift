import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var draft = AppSettings()

    @State private var openInventory = false
    @State private var openPrice = false
    @State private var openSync = false
    @State private var openAI = false
    @State private var showFolderPicker = false
    @State private var showTestAlert = false
    @State private var openPcStatus = false
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

                // 和电脑同步
                DisclosureGroup(isExpanded: $openSync) {
                    TextField("https://chenyegames.ddns.net:5188", text: $draft.pcBaseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("同步密钥", text: $draft.syncKey)
                    Button {
                        store.settings = draft
                        store.saveSettings()
                        Task { _ = await store.syncAcks() }
                    } label: {
                        HStack {
                            Text("立即同步确认记录")
                            if store.syncingAcks {
                                Spacer()
                                ProgressView().scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(store.syncingAcks)

                    if !store.lastAcksMessage.isEmpty {
                        Text(store.lastAcksMessage)
                            .font(.caption)
                            .foregroundStyle(store.lastAcksMessage.hasPrefix("同步成功")
                                             ? Theme.ok : Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("电脑关机时不影响手机使用，下次连上会自动补上。")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                } label: {
                    label("和电脑同步", detail: store.pendingAcks > 0
                          ? "\(store.pendingAcks) 条待推送"
                          : (draft.syncKey.isEmpty ? "未配置" : "已同步"))
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

                DisclosureGroup(isExpanded: $openPcStatus) {
                    HStack {
                        Text(pcStatusText)
                            .font(.footnote)
                            .foregroundStyle(pcStatusColor)
                        Spacer()
                    }

                    Text(store.pendingAcks > 0
                         ? "\(store.pendingAcks) 条确认在等你推送（只存在手机里，不影响查库存）"
                         : "没有待推送的确认")
                        .font(.caption)
                        .foregroundStyle(store.pendingAcks > 0 ? Theme.warn : Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(store.lastAcksMessage.isEmpty ? "还没同步过" : store.lastAcksMessage)
                        .font(.footnote)
                        .foregroundStyle(store.lastAcksMessage.hasPrefix("同步成功")
                                         ? Theme.ok : Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        store.settings = draft
                        Task { _ = await store.syncAcks() }
                    } label: {
                        HStack {
                            Text(store.syncingAcks ? "正在同步…" : "开始同步（推送 + 拉取）")
                            Spacer()
                            if store.syncingAcks { ProgressView() }
                        }
                    }
                    .disabled(store.syncingAcks)

                    Text("补货确认只存在手机里：这里的同步只负责把确认推给电脑、把电脑的确认拉回来。和库存/价格表的同步互不影响。")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    HStack {
                        Text("电脑端同步状态")
                        Spacer()
                        Text("手动")
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
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
                    Text("备份包含：令牌、密钥、每日快照、补货确认。换证书或删了重装后，从这里一键恢复。")
                        .foregroundStyle(Theme.muted)
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

    private var pcStatusText: String {
        if store.pendingAcks > 0 { return "\(store.pendingAcks) 条待推送" }
        if store.lastAcksMessage.hasPrefix("同步成功") { return "已连接" }
        if store.lastAcksMessage.hasPrefix("同步失败") { return "未连接" }
        return "未同步"
    }

    private var pcStatusColor: Color {
        if store.pendingAcks > 0 { return Theme.warn }
        if store.lastAcksMessage.hasPrefix("同步成功") { return Theme.ok }
        if store.lastAcksMessage.hasPrefix("同步失败") { return Theme.danger }
        return Theme.muted
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
