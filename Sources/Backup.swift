import Foundation

/// 备份包：换证书、删了重装时用来恢复
struct BackupFile: Codable {
    var version = 1
    var createdAt: String
    var settings: AppSettings
    var snapshots: [String: [String: Double]]
    var acks: [String]
    var pushed: [String]
    var productCount: Int
}

enum Backup {

    static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func fileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return "AI小助手备份-\(f.string(from: Date())).json"
    }

    /// 把当前数据打包写成文件，返回路径
    static func export(settings: AppSettings,
                       snapshots: [String: [String: Double]],
                       acks: Set<String>,
                       pushed: Set<String>,
                       productCount: Int) throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let pack = BackupFile(
            createdAt: f.string(from: Date()),
            settings: settings,
            snapshots: snapshots,
            acks: Array(acks).sorted(),
            pushed: Array(pushed).sorted(),
            productCount: productCount
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(pack)
        let url = dir.appendingPathComponent(fileName())
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 读回来
    static func load(from url: URL) throws -> BackupFile {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BackupFile.self, from: data)
    }

    /// 清掉旧备份，只留最近 3 个
    static func cleanupOld() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let backups = files.filter { $0.lastPathComponent.hasPrefix("AI小助手备份-") }
        guard backups.count > 3 else { return }
        let sorted = backups.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for old in sorted.dropFirst(3) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
