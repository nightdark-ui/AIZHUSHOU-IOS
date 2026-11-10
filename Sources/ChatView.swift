import SwiftUI
import UIKit

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @State private var input = ""
    @State private var showModelInfo = false
    @State private var previewPaths: [String] = []
    @State private var previewIndex = 0
    @State private var previewState: PreviewState?
    @State private var saveHint = ""
    @State private var imageSelectMode = false
    @State private var selectedImages: [String: String] = [:]
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
                ToolbarItem(placement: .topBarLeading) {
                    modelPill
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        if store.syncing {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 9, weight: .medium))
                        } else {
                            MiniClock(size: 9)
                        }
                        Text(store.syncing ? "同步中…" : store.lastSyncTimeText)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.panel)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                }
            }
            .overlay(alignment: .bottom) {
                if imageSelectMode {
                    HStack(spacing: 14) {
                        Button {
                            exitImageSelect()
                        } label: {
                            Text("取消").pill()
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Text("已选 \(selectedImages.count) 张")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)

                        Button {
                            saveSelectedImages()
                        } label: {
                            Text("保存到相册")
                                .pill(active: !selectedImages.isEmpty, filled: !selectedImages.isEmpty)
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedImages.isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.panel)
                    .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
                }
            }
            .overlay {
                if let state = previewState {
                    viewer(state)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.75, anchor: .center).combined(with: .opacity),
                            removal: .scale(scale: 0.9, anchor: .center).combined(with: .opacity)))
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: previewState != nil)
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
        HStack(alignment: .top, spacing: 8) {
            if isUser {
                Spacer(minLength: 44)
            } else {
                avatar
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                // 气泡宽度上限，保证长文本折行
                Text(line.text)
                    .font(.system(size: 15))
                    .foregroundStyle(isUser ? .white : Theme.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
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
                if !line.options.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(line.options, id: \.self) { sku in
                            Button {
                                Task { await store.ask(sku) }
                            } label: {
                                Text(sku).pill()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }

                if !line.images.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(line.images.enumerated()), id: \.offset) { idx, path in
                            let key = "\(line.id.uuidString)|\(path)"
                            ZStack(alignment: .topLeading) {
                                thumb(path)
                                if imageSelectMode {
                                    Image(systemName: selectedImages[key] != nil
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22))
                                        .foregroundStyle(selectedImages[key] != nil ? Theme.ok : .white)
                                        .padding(6)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if imageSelectMode {
                                    toggleImage(key: key, path: path)
                                } else {
                                    openPreview(path: path, fallback: line.images)
                                }
                            }
                            .onLongPressGesture(minimumDuration: 0.45) {
                                if !imageSelectMode { imageSelectMode = true }
                                selectedImages[key] = path
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if !isUser { Spacer(minLength: 44) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.leading, isUser ? 0 : 0)
    }

    private var bubbleWidth: CGFloat {
        max(200, UIScreen.main.bounds.width - 110)
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
        .frame(width: 150, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Theme.line, lineWidth: 1))
    }

    private func viewer(_ state: PreviewState) -> some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { previewState = nil }

            TabView(selection: $previewIndex) {
                ForEach(Array(state.paths.enumerated()), id: \.offset) { idx, path in
                    page(path).tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: state.paths.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            .padding(.vertical, 40)
        }
        .overlay(alignment: .bottom) {
            if !saveHint.isEmpty {
                Text(saveHint)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Capsule())
                    .padding(.bottom, 50)
            }
        }
    }

    private func page(_ path: String) -> some View {
        Group {
            if let img = UIImage(contentsOfFile: path) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Color.black.opacity(0.18), radius: 16, y: 6)
                        .onTapGesture { previewState = nil }
                        .contextMenu {
                            Button {
                                saveToAlbum(path)
                            } label: {
                                Label("保存到相册", systemImage: "photo")
                            }
                            ShareLink(item: Image(uiImage: img),
                                      preview: SharePreview("款式图片", image: Image(uiImage: img))) {
                                Label("转发到其他 App", systemImage: "square.and.arrow.up")
                            }
                        }

                    Button {
                        previewState = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    .padding(10)
                }
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在打开…").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func toggleImage(key: String, path: String) {
        if selectedImages[key] != nil {
            selectedImages.removeValue(forKey: key)
        } else {
            selectedImages[key] = path
        }
    }

    private func exitImageSelect() {
        imageSelectMode = false
        selectedImages.removeAll()
    }

    /// 打开预览：路径池是「整个对话里的所有图」，可以左右滑到别的消息
    private func openPreview(path: String, fallback: [String]) {
        var all: [String] = []
        for line in store.chat {
            for p in line.images where !all.contains(p) { all.append(p) }
        }
        if all.isEmpty { all = fallback }
        let idx = all.firstIndex(of: path) ?? 0
        previewPaths = all
        previewIndex = idx
        previewState = PreviewState(paths: all, index: idx)
    }

    /// 批量保存到相册
    private func saveSelectedImages() {
        var saved = 0
        for path in Set(selectedImages.values) {
            guard let img = UIImage(contentsOfFile: path) else { continue }
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            saved += 1
        }
        saveHint = saved > 0 ? "已保存 \(saved) 张到相册" : "没有可保存的图片"
        exitImageSelect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if saveHint.hasPrefix("已保存") { saveHint = "" }
        }
    }

    private func saveToAlbum(_ path: String) {
        guard let img = UIImage(contentsOfFile: path) else {
            saveHint = "图片读不出来"
            return
        }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        saveHint = "已保存到相册"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if saveHint == "已保存到相册" { saveHint = "" }
        }
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

struct PreviewState: Identifiable {
    let id = UUID()
    var paths: [String]
    var index: Int
}
