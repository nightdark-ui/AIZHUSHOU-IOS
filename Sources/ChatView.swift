import SwiftUI
import UIKit

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @State private var input = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(store.chat) { line in
                                bubble(line).id(line.id)
                            }
                            if store.thinking {
                                HStack(spacing: 6) {
                                    ProgressView()
                                    Text("正在想…").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.leading, 12)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: store.chat.count) { _, _ in
                        if let last = store.chat.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("问编号或问题，比如：2002 库存", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit { send() }
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("AI小助手")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(store.lastSyncText).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func send() {
        let text = input
        input = ""
        Task { await store.ask(text) }
    }

    @ViewBuilder
    private func bubble(_ line: ChatLine) -> some View {
        HStack {
            if line.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                Text(line.text)
                    .padding(10)
                    .background(line.role == "user" ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if !line.mode.isEmpty && line.role == "assistant" {
                    Text(line.mode == "llm" ? "DeepSeek" : "本地规则")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
            if line.role == "assistant" { Spacer(minLength: 40) }
        }
    }
}
