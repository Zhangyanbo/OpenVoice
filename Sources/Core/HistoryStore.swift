import Foundation
import Combine

/// 转录历史,只存本地(~/Library/Application Support/OpenVoice/history.json)。
/// 方便用户回头复制某次转录结果;可在设置中关闭或一键清空。
///
/// 录音文件为「重新转录」服务,持久化在 recordings/ 子目录(以条目 UUID 命名):
/// - 只保留最近 N 条的录音,超出的文件随即从磁盘删除;
/// - 清理时机:每次新增转录条目时 + 应用启动对账时(两个必然触发的事件,
///   不依赖任何可能不发生的回调);
/// - 启动时还会删除孤儿录音文件(对应历史条目已不存在),磁盘占用有硬上限。
final class HistoryStore: ObservableObject {
    /// 重新转录所需的原始模式信息(历史条目里只存可编码的简单值)。
    /// context* 为录音瞬间的上下文快照,保证重新转录结果可复现;
    /// 全部可选——旧版本条目没有这些字段,解码为 nil 后回退到现场采集。
    struct RetryInfo: Codable {
        /// "dictation" / "translation"
        var kind: String
        /// 翻译模式的目标语言
        var target: String?
        var contextApp: String?
        var contextWindow: String?
        var contextSelected: String?
        var contextBefore: String?
        var contextAfter: String?
    }

    struct Entry: Codable, Identifiable {
        var id = UUID()
        /// 失败条目不存正文,显示层按 failed 渲染本地化的「转录失败」
        var text: String
        var date = Date()
        /// 如 "语音" / "翻译 → 英语"(已按界面语言本地化)
        var mode: String
        var appName: String?
        var failed: Bool = false
        var retry: RetryInfo?

        private enum CodingKeys: String, CodingKey { case id, text, date, mode, appName, failed, retry }

        /// 手写解码:旧版本历史文件没有 failed/retry 字段。
        /// 合成的 Codable 遇到缺失键会抛错并丢弃整个列表,这里必须用 decodeIfPresent 兜底。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            text = try c.decode(String.self, forKey: .text)
            date = try c.decode(Date.self, forKey: .date)
            mode = try c.decode(String.self, forKey: .mode)
            appName = try c.decodeIfPresent(String.self, forKey: .appName)
            failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
            retry = try c.decodeIfPresent(RetryInfo.self, forKey: .retry)
        }

        /// 自定义 init(from:) 会抑制逐成员构造器,这里显式提供
        init(text: String, mode: String, appName: String?,
             failed: Bool = false, retry: RetryInfo? = nil) {
            self.id = UUID()
            self.text = text
            self.date = Date()
            self.mode = mode
            self.appName = appName
            self.failed = failed
            self.retry = retry
        }
    }

    static let shared = HistoryStore()
    private static let maxEntries = 200
    /// 最多保留多少条录音供重新转录
    private static let maxRetainedRecordings = 10

    @Published private(set) var entries: [Entry] = []
    /// 当前有录音文件的条目(启动对账后建立,增删时同步维护)
    private(set) var recordingIDs = Set<UUID>()
    /// 正在重新转录的条目(行内旋转指示)
    @Published private(set) var retranscribingID: UUID?

    private let fileURL = AppPaths.supportDirectory.appendingPathComponent("history.json")
    private let recordingsDirectory = AppPaths.supportDirectory.appendingPathComponent("recordings", isDirectory: true)

    private init() {
        try? FileManager.default.createDirectory(at: recordingsDirectory,
                                                 withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: fileURL) else {
            reconcileRecordings(validIDs: [])
            return
        }
        if let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
            reconcileRecordings(validIDs: Set(entries.map(\.id)))
        } else {
            // 解码失败时把原文件改名备份,绝不让后续 save() 用空列表覆盖用户数据
            let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? data.write(to: backup, options: .atomic)
            NSLog("HistoryStore: 解码失败,原文件已备份为 \(backup.lastPathComponent)")
            reconcileRecordings(validIDs: [])
        }
    }

    // MARK: - 增删查

    func add(text: String, mode: String, appName: String?,
             failed: Bool = false, wav: Data? = nil, retry: RetryInfo? = nil) {
        guard !text.isEmpty || failed else { return }
        let entry = Entry(text: text, mode: mode, appName: appName, failed: failed, retry: retry)
        entries.insert(entry, at: 0)

        // 写录音文件(有新转录就顺手执行保留上限检查,清理不会漏)
        if let wav {
            try? wav.write(to: recordingURL(entry.id), options: .atomic)
            recordingIDs.insert(entry.id)
        }

        if entries.count > Self.maxEntries {
            let overflow = entries.count - Self.maxEntries
            for stale in entries.suffix(overflow) { deleteRecordingFile(stale.id) }
            entries.removeLast(overflow)
        }
        trimRetainedRecordings()
        save()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        deleteRecordingFile(entry.id)
        save()
    }

    func clear() {
        entries = []
        recordingIDs.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        save()
    }

    /// 该条目是否还有可重新转录的录音
    func canRetranscribe(_ id: UUID) -> Bool {
        recordingIDs.contains(id)
    }

    func recordingData(for id: UUID) -> Data? {
        guard canRetranscribe(id) else { return nil }
        return try? Data(contentsOf: recordingURL(id))
    }

    // MARK: - 重新转录状态

    /// 标记某条目进入/退出重新转录状态(行内显示旋转指示)
    func setRetranscribing(_ id: UUID?) {
        retranscribingID = id
    }

    /// 原地更新条目(重新转录成功后替换正文),不动位置与其他字段
    func updateEntry(_ id: UUID, _ mutate: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[index])
        save()
    }

    // MARK: - 录音文件管理

    /// 启动对账:删除孤儿文件,并按保留上限裁剪
    private func reconcileRecordings(validIDs: Set<UUID>) {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                guard file.pathExtension.lowercased() == "wav",
                      let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                    try? fm.removeItem(at: file) // 非法命名的文件一律清掉
                    continue
                }
                if !validIDs.contains(id) {
                    try? fm.removeItem(at: file) // 历史条目已不存在的孤儿录音
                }
            }
        }
        recordingIDs = validIDs.filter { fm.fileExists(atPath: recordingURL($0).path) }
        trimRetainedRecordings()
    }

    /// 从最新往旧数,只保留前 maxRetainedRecordings 条的录音文件。
    /// 注意 entries 是新的在前(insert at 0),必须正序遍历;
    /// 曾经写成 .reversed() 导致保留的是最旧的、删掉刚录的(spec 回归教训)
    private func trimRetainedRecordings() {
        var count = 0
        for i in entries.indices where recordingIDs.contains(entries[i].id) {
            count += 1
            if count > Self.maxRetainedRecordings {
                deleteRecordingFile(entries[i].id)
            }
        }
    }

    private func deleteRecordingFile(_ id: UUID) {
        try? FileManager.default.removeItem(at: recordingURL(id))
        recordingIDs.remove(id)
    }

    private func recordingURL(_ id: UUID) -> URL {
        recordingsDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("wav")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
