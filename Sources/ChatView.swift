import SwiftUI
import UIKit

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var speech = SpeechListener()
    @State private var input = ""
    @State private var showModelInfo = false
    @State private var preview: String?
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

                if !speech.errorText.isEmpty {
                    Text(speech.errorText)
                        .font(.caption2)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                }

                composer
            }
            .navigationTitle("AI 小助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    modelPill
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(store.syncing ? "同步中…" : store.lastSyncText)
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                }
            }
            .onChange(of: speech.text) { _, newValue in
                if !newValue.isEmpty { input = newValue }
            }
            .sheet(item: Binding(
                get: { preview.map { PreviewPath(path: $0) } },
                set: { if $0 == nil { preview = nil } }
            )) { item in
                fullImage(item.path)
            }
            .alert("模型状态", isPresented: $showModelInfo) {
                Button("测试连接") { Task { await store.testModel() } }
                Button("好", role: .cancel) {}
            } message: {
                Text(modelDescription)
            }
        }
    }

    private var modelDescription: String {
        if !store.modelConfigured { return "还没填 DeepSeek API Key，复杂问题会用本地的规则回答。" }
        if store.modelStatus.isEmpty { return "已配置 DeepSeek。点「测试连接」看看能不能通。" }
        return store.modelStatus
    }

    private var modelPill: some View {
        Button {
            showModelInfo = true
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(store.modelConfigured ? Theme.ok : Theme.muted)
                    .frame(width: 7, height: 7)
                Text(store.modelConfigured ? "DeepSeek" : "未配置")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.panel)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Button {
                speech.toggle()
                if speech.listening { focused = false }
            } label: {
                Image(systemName: speech.listening ? "mic.fill" : "mic")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(speech.listening ? .white : Theme.brand)
                    .frame(width: 36, height: 36)
                    .background(speech.listening ? Theme.danger : Theme.brandSoft)
                    .clipShape(Circle())
            }

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
        speech.stop()
        Task { await store.ask(text) }
    }

    @ViewBuilder
    private func bubble(_ line: ChatLine) -> some View {
        let isUser = line.role == "user"
        HStack(alignment: .top, spacing: 8) {
            if isUser {
                Spacer(minLength: 44)
            } else {
                avatar
            }

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
                if !line.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(line.images, id: \.self) { path in
                            Button {
                                preview = path
                            } label: {
                                thumb(path)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if !isUser { Spacer(minLength: 44) }
        }
    }

    private func thumb(_ path: String) -> some View {
        Group {
            if let img = UIImage(contentsOfFile: path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Theme.bg)
                    .overlay(Image(systemName: "photo").foregroundStyle(Theme.muted))
            }
        }
        .frame(width: 78, height: 78)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Theme.line, lineWidth: 1))
    }

    private func fullImage(_ path: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("关闭") { preview = nil }
                    .padding()
            }
            ScrollView([.horizontal, .vertical]) {
                if let img = UIImage(contentsOfFile: path) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                }
            }
        }
        .background(Color.black)
    }

    private var avatar: some View {
        Image("LaunchLogo")
            .resizable()
            .scaledToFill()
            .frame(width: 30, height: 30)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.line, lineWidth: 1))
    }
}

struct PreviewPath: Identifiable {
    let path: String
    var id: String { path }
}
