import AppKit

/// 录音开始时的短提示音(spec §2)。用系统内置音效,不带资源文件。
enum SoundPlayer {
    static func playStart() {
        NSSound(named: "Tink")?.play()
    }
}
