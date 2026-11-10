import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var draft = AppSettings()

    var body: some View {
        NavigationStack {
            Form {
                Section("库存表") {
                    SecureField("AirScript 令牌", text: $draft.inventoryToken)
                    TextField("文件 ID", text: $draft.inventoryFileId)
                    TextField("脚本 ID", text: $draft.inventoryScriptId)
                }

                Section("价格表") {
                    SecureField("AirScript 令牌", text: $draft.priceToken)
                    TextField("文件 ID", text: $draft.priceFileId)
                    TextField("脚本 ID", text: $draft.priceScriptId)
                }

                Section("补货") {
                    HStack {
                        Text("提醒线")
                        Spacer()
                        TextField("300", value: $draft.threshold, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("AI（后面版本用）") {
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
                        Text("保存并同步").frame(maxWidth: .infinity)
                    }
                }

                Section("状态") {
                    Text(store.statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .onAppear { draft = store.settings }
        }
    }
}
