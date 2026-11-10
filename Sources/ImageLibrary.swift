import Foundation
import SwiftUI

/// 手机上的图库：用户手动选一个文件夹，按编号找图
///
/// 支持两种图库：
///   ① 文件名就是编号（2002.jpg）
///   ② 文件名是哈希，靠目录里的 codes.json 映射
///      codes.json 可以写相对路径，也可以只写文件名（改名也不怕）
@MainActor
final class ImageLibrary: ObservableObject {

    @Published var folderName = ""
    @Published var fileCount = 0
    @Published var building = false
    @Published var errorText = ""
    @Published var mapped = false

    private let bookmarkKey = "aizhushou.library.bookmark"
    private var exact: [String: [URL]] = [:]     // 编号 -> 图（来自 codes.json 或文件名）
    private var base: [String: [URL]] = [:]      // 前缀 -> 图（2002 也含 2002-1）
    private var byName: [String: URL] = [:]      // 文件名 -> 图（给映射兜底）

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
            errorText = ""
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
        errorText = ""
        defer { building = false }

        let ok = root.startAccessingSecurityScopedResource()
        defer { if ok { root.stopAccessingSecurityScopedResource() } }

        // ① 先扫一遍，建文件名索引 + 按文件名当编号的索引
        var nameMap: [String: URL] = [:]
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

                let fileName = url.lastPathComponent
                nameMap[fileName.uppercased()] = url

                let stem = url.deletingPathExtension().lastPathComponent.uppercased()
                guard !stem.isEmpty else { continue }
                exactMap[stem, default: []].append(url)
                if let r = stem.range(of: "[-_（(]", options: .regularExpression) {
                    let b = String(stem[..<r.lowerBound])
                    if !b.isEmpty { baseMap[b, default: []].append(url) }
                }
            }
        }

        // ② 有 codes.json 就用它（哈希文件名也能对上）
        if let mapping = loadMapping(root: root, byName: nameMap) {
            exact = mapping
            base = [:]
            byName = nameMap
            fileCount = total
            mapped = true
            folderName = root.lastPathComponent
            if mapping.isEmpty { errorText = "codes.json 里的图片一张都没找到" }
            return
        }

        // ③ 没有映射：就当文件名是编号
        exact = exactMap
        base = baseMap
        byName = nameMap
        fileCount = total
        mapped = false
        folderName = root.lastPathComponent

        if total == 0 {
            errorText = "这个文件夹里没找到图片"
        } else if exactMap.count < 10 {
            errorText = "文件名不像编号（没找到 codes.json），建议放一份映射文件进来"
        }
    }

    /// 读 codes.json：{"2002": ["a.jpg"]} 或 {"2002": ["Gallery/images/a.jpg"]}
    private func loadMapping(root: URL, byName: [String: URL]) -> [String: [URL]]? {
        for n in ["codes.json", "图库索引.json", "index.json"] {
            let u = root.appendingPathComponent(n)
            guard let data = try? Data(contentsOf: u) else { continue }

            var out: [String: [URL]] = [:]
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
                for (code, list) in dict {
                    var urls: [URL] = []
                    for item in list {
                        let key = (item as NSString).lastPathComponent.uppercased()
                        if let hit = byName[key] {
                            urls.append(hit)
                        } else {
                            let direct = root.appendingPathComponent(item)
                            if FileManager.default.fileExists(atPath: direct.path) {
                                urls.append(direct)
                            }
                        }
                    }
                    if !urls.isEmpty { out[code.uppercased()] = urls }
                }
            } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                // 也支持 [{"code": "2002", "files": [...]}]
                for row in arr {
                    guard let code = row["code"] as? String else { continue }
                    let files = (row["files"] as? [String]) ?? []
                    var urls: [URL] = []
                    for item in files {
                        let key = (item as NSString).lastPathComponent.uppercased()
                        if let hit = byName[key] { urls.append(hit) }
                    }
                    if !urls.isEmpty { out[code.uppercased()] = urls }
                }
            }
            if !out.isEmpty { return out }
        }
        return nil
    }

    // MARK: - 按编号取图（拷到沙盒里再显示）

    func images(for sku: String, limit: Int = 4) -> [String] {
        guard let root = folderURL() else { return [] }
        let key = sku.uppercased()

        var urls = exact[key] ?? []
        if urls.count < limit {
            for u in (base[key] ?? []) where !urls.contains(u) { urls.append(u) }
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

    func hasImage(for sku: String) -> Bool {
        let key = sku.uppercased()
        return exact[key] != nil || base[key] != nil
    }
}
