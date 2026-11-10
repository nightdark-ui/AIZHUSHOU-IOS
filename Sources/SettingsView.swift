import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var draft = AppSettings()
    @State private var syncResult = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("AirScript 令牌", text: $draft.inventoryToken)
                    TextField("文件 ID", text: $draft.inventoryFileId)
                    TextField("脚本 ID", text: $draft.inventoryScriptId)
                } header: {
                    Text("库存表")
                }

                Section {
                    SecureField("AirScript 令牌", text: $draft.priceToken)
                    TextField("文件 ID", text: $draft.priceFileId)
                    TextField("脚本 ID", text: $draft.priceScriptId)
                } header: {
                    Text("价格表")
                } footer: {
                    Text("价格表只在打开 App 和点「保存并同步」时拉取。")
                }

                Section {
                    TextField("https://chenyegames.ddns.net:5188", text: $draft.pcBaseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("同步密钥", text: $draft.syncKey)
                    Button {
                        store.settings = draft
                        Task {
                            await store.syncAcks()
                            syncResult = store.statusText
                        }
                    } label: {
                        Text("立即同步确认记录")
                    }
                } header: {
                    Text("和电脑同步")
                } footer: {
                    Text("电脑关机时不影响手机使用，下次连上会自动补上。")
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
                    Text("有补货时，每天 9 点提醒一次。可在系统设置里关闭。")
                }

                Section("AI 对话") {
                    SecureField("DeepSeek API Key", text: $draft.deepSeekKey)
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
            .onAppear { draft = store.settings }
        }
    }
}
