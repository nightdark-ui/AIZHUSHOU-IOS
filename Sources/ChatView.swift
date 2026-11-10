import SwiftUI
import UIKit

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(store.chat) { line in
                                bubble(line).id(line.id)
                            }
                            if store.thinking {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.8)
                                    Text("正在想…").font(.caption).foregroundStyle(Theme.muted)
                                }
                                .padding(.leading, 12)
                            }
                        }
                        .padding(14)
                    }
                    .background(Theme.bg)
                    .onChange(of: store.chat.count) { _, _ in
                        if let last = store.chat.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                composer
            }
            .navigationTitle("AI 小助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(store.syncing ? "同步中…" : store.lastSyncText)
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("问编号或问题，比如：2002 库存", text: $input)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { send() }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.bg)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(input.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Theme.muted.opacity(0.4) : Theme.brand)
                    .clipShape(Circle())
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }

    private func send() {
        let text = input
        input = ""
        Task { await store.ask(text) }
    }

    @ViewBuilder
    private func bubble(_ line: ChatLine) -> some View {
        let isUser = line.role == "user"
        HStack(alignment: .bottom) {
            if isUser { Spacer(minLength: 44) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Text(line.text)
                    .font(.system(size: 15))
                    .foregroundStyle(isUser ? .white : Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(isUser ? Theme.brand : Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isUser ? Color.clear : Theme.line, lineWidth: 1)
                    )
                if !isUser && !line.mode.isEmpty {
                    Text(line.mode == "llm" ? "DeepSeek" : "本地规则")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted)
                        .padding(.leading, 3)
                }
            }
            if !isUser { Spacer(minLength: 44) }
        }
    }
}
