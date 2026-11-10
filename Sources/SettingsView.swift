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
                        Task { await store.syncAcks() }
                    } label: {
                        Text("立即同步确认记录")
                    }
                    Text("电脑关机时不影响手机使用，下次连上会自动补上。")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                } label: {
                    label("和电脑同步", detail: draft.syncKey.isEmpty ? "未配置" : "已配置")
                }

                // AI
                DisclosureGroup(isExpanded: $openAI) {
                    SecureField("DeepSeek API Key", text: $draft.deepSeekKey)
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
                            Task { await store.library.rebuild() }
                        } label: {
                            Text(store.library.building ? "正在建索引…" : "重建索引（\(store.library.fileCount) 张图\(store.library.mapped ? " · 已读映射" : "")）")
                        }
                        .disabled(store.library.building)
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

                Section {
                    HStack {
                        Text("默认提醒线")
                        Spacer()
                        TextField("300", value: $draft.threshold, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Button {
                        Notifier.requestPermission()
                        Notifier.test()
                    } label: {
                        Text("测试通知（5 秒后）")
                    }
                } header: {
                    Text("补货提醒")
                } footer: {
                    Text("每次刷新库存发现补货就提醒一次（5 分钟内不重复）。")
                        .foregroundStyle(Theme.muted)
                }

                Section {
                    Button {
                        store.settings = draft
                        store.saveSettings()
                    } label: {
                        Text("保存").frame(maxWidth: .infinity)
                    }
                    Button {
                        store.settings = draft
                        Task { await store.saveAndSync() }
                    } label: {
                        Text("保存并同步（库存 + 价格）").frame(maxWidth: .infinity)
                    }
                }

                Section("状态") {
                    Text(store.statusText)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
            .navigationTitle("设置")
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.library.setFolder(url)
                }
            }
            .onAppear { draft = store.settings }
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
