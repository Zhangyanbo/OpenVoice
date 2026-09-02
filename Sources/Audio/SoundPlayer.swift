import AppKit
import AVFoundation

/// 提示音。用系统内置音效,不带资源文件。
enum SoundPlayer {
    private static let startPlayer = makePlayer(named: "Submarine")
    private static let endPlayer = makePlayer(named: "Bottle")
    private static let failurePlayer = makePlayer(named: "Funk")

    /// App 启动时就解码三个音效，避免第一次按 Fn 时才从磁盘加载。
    static func prepare() {
        _ = startPlayer
        _ = endPlayer
        _ = failurePlayer
    }

    /// 录音开始提示音(spec §2)
    static func playStart() {
        play(startPlayer, fallbackName: "Submarine")
    }

    /// 正常结束录音。
    static func playEnd() {
        play(endPlayer, fallbackName: "Bottle")
    }

    /// 录音中断或本次语音输入失败。
    static func playFailure() {
        play(failurePlayer, fallbackName: "Funk")
    }

    private static func makePlayer(named name: String) -> AVAudioPlayer? {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        return player
    }

    private static func play(_ player: AVAudioPlayer?, fallbackName: String) {
        guard let player else {
            NSSound(named: NSSound.Name(fallbackName))?.play()
            return
        }
        player.currentTime = 0
        player.play()
    }
}
