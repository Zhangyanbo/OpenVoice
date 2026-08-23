import AppKit

/// 提示音。用系统内置音效,不带资源文件。
/// 注意选中性的音效:Tink/Basso 等在 macOS 语境里是错误提示音,不能用。
enum SoundPlayer {
    /// 录音开始提示音(spec §2)
    static func playStart() {
        NSSound(named: "Pop")?.play()
    }

    /// 快捷键按下的短促反馈音,比开始提示音更轻
    static func playKeyClick() {
        guard let sound = NSSound(named: "Pop") else { return }
        sound.volume = 0.45
        sound.play()
    }
}
