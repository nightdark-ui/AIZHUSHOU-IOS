import Foundation
import SwiftUI

/// 手机上的图库：用户手动选一个文件夹，按编号找图
@MainActor
final class ImageLibrary: ObservableObject {

    @Published var folderName = ""
    @Published var fileCount = 0
    @Published var building = false
    @Published var errorText = ""

    private let bookmarkKey = "aizhushou.library.bookmark"
    private var exact: [String: [URL]] = [:]     // 2002-1 -> [url]
    private var base: [String: [URL]] = [:]      // 2002  -> [url]（含 2002-1、2002(32梭)）

    private static let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "bmp", "gif"]

    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library", isDirectory: true)
    }

    var hasFolder: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    // MARK: - 选文件夹

    func setFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try url.bookmarkData(options: [],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            folderName = url.lastPathComponent
            Task { await rebuild() }
        } catch {
            errorText = "保存文件夹失败：\(error.localizedDescription)"
        }
    }

    func folderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    // MARK: - 建索引

    func rebuild() async {
        guard let root = folderURL() else {
            errorText = "还没选文件夹"
            return
        }
        building = true
        defer { building = false }

        let ok = root.startAccessingSecurityScopedResource()
        defer { if ok { root.stopAccessingSecurityScopedResource() } }

        var exactMap: [String: [URL]] = [:]
        var baseMap: [String: [URL]] = [:]
        var total = 0

        let fm = FileManager.default
        if let it = fm.enumerator(at: root,
                                  includingPropertiesForKeys: [.isRegularFileKey],
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in it {
                let ext = url.pathExtension.lowercased()
                guard Self.exts.contains(ext) else { continue }
                total += 1

                let stem = url.deletingPathExtension().lastPathComponent.uppercased()
                if stem.isEmpty { continue }
                exactMap[stem, default: []].append(url)

                // 2002-1 / 2002(32梭）→ 也算 2002 的图
                if let r = stem.range(of: "[-_（(]", options: .regularExpression) {
                    let b = String(stem[..<r.lowerBound])
                    if !b.isEmpty { baseMap[b, default: []].append(url) }
                }
            }
        }

        exact = exactMap
        base = baseMap
        fileCount = total
        folderName = root.lastPathComponent
        if total == 0 { errorText = "这个文件夹里没找到图片" }
    }

    // MARK: - 按编号取图（拷到沙盒里再显示）

    func images(for sku: String, limit: Int = 4) -> [String] {
        guard let root = folderURL() else { return [] }
        let key = sku.uppercased()

        var urls = exact[key] ?? []
        if urls.count < limit {
            let extra = base[key] ?? []
            for u in extra where !urls.contains(u) { urls.append(u) }
        }
        guard !urls.isEmpty else { return [] }

        let ok = root.startAccessingSecurityScopedResource()
        defer { if ok { root.stopAccessingSecurityScopedResource() } }

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        var out: [String] = []
        for src in urls.prefix(limit) {
            let dst = cacheDir.appendingPathComponent(key + "__" + src.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.copyItem(at: src, to: dst)
            }
            if FileManager.default.fileExists(atPath: dst.path) {
                out.append(dst.path)
            }
        }
        return out
    }

    /// 索引里到底有没有这个款
    func hasImage(for sku: String) -> Bool {
        let key = sku.uppercased()
        return exact[key] != nil || base[key] != nil
    }
}
