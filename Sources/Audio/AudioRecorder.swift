import Foundation
import AVFoundation

/// AVAudioEngine 录音,统一转成 16kHz 单声道 16-bit WAV(内存中,不落盘)。
/// 录音结束后立即释放引擎,停止占用麦克风(spec §15)。
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pcmData = Data()
    private let targetSampleRate: Double = 16000

    /// 每个音频 buffer 的音量回调(0...1),用于悬浮条动画;主线程调用
    var onLevel: ((Float) -> Void)?

    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return }
        pcmData = Data()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可用的录音设备。"])
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: targetSampleRate,
                                               channels: 1,
                                               interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法初始化音频转换。"])
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        isRecording = true
    }

    /// 停止并返回 WAV 数据;太短(< 0.3s)返回 nil
    func stop() -> Data? {
        guard isRecording else { return nil }
        isRecording = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil

        let minBytes = Int(targetSampleRate * 0.3) * 2
        guard pcmData.count >= minBytes else { return nil }
        return Self.wavFile(fromPCM: pcmData, sampleRate: Int(targetSampleRate))
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        pcmData = Data()
    }

    private func process(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        // 音量(RMS)
        if let ch = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            if n > 0 {
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = sqrt(sum / Float(n))
                // 粗略映射到 0...1
                let level = min(1, rms * 12)
                DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
            }
        }

        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let int16 = out.int16ChannelData?[0] else { return }
        pcmData.append(UnsafeBufferPointer(start: int16, count: Int(out.frameLength)))
    }

    // MARK: - WAV 封装

    static func wavFile(fromPCM pcm: Data, sampleRate: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * 2
        func append(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(16)
        append16(1)                    // PCM
        append16(1)                    // mono
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append16(2)                    // block align
        append16(16)                   // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

private extension Data {
    mutating func append(_ buffer: UnsafeBufferPointer<Int16>) {
        buffer.baseAddress.map {
            append(UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), count: buffer.count * 2)
        }
    }
}
