import Foundation
import Combine

/// 转录历史,只存本地(~/Library/Application Support/OpenVoiceInput/history.json)。
/// 方便用户回头复制某次转录结果;可在设置中关闭或一键清空。
final class HistoryStore: ObservableObject {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        var text: String
        var date = Date()
        /// 如 "语音" / "翻译 → 英语"
        var mode: String
        var appName: String?
    }

    static let shared = HistoryStore()
    private static let maxEntries = 200

    @Published private(set) var entries: [Entry] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenVoiceInput", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    func add(text: String, mode: String, appName: String?) {
        guard !text.isEmpty else { return }
        entries.insert(Entry(text: text, mode: mode, appName: appName), at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
