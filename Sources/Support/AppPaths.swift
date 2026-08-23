import Foundation

/// 本地数据目录。应用由 OpenVoiceInput 改名 OpenVoice 后,
/// 旧目录整体迁移一次,老用户的术语表/历史无缝保留。
enum AppPaths {
    static let supportDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent("OpenVoice", isDirectory: true)
        let legacy = base.appendingPathComponent("OpenVoiceInput", isDirectory: true)
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }()
}
