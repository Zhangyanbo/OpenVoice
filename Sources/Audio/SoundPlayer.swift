import AppKit

/// 录音开始时的短提示音(spec §2)。用系统内置音效,不带资源文件。
/// 注意选中性的音效:Tink/Basso 等在 macOS 语境里是错误提示音,不能用。
enum SoundPlayer {
    static func playStart() {
        NSSound(named: "Pop")?.play()
    }
}
