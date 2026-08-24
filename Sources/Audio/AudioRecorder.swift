import Foundation
import AVFoundation

/// AVAudioEngine 录音,统一转成 16kHz 单声道 16-bit WAV(内存中,不落盘)。
/// 录音结束后立即释放引擎,停止占用麦克风(spec §15)。
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var converterSourceSampleRate: Double = 0
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
        // 开启后走系统 Voice Processing(回声消除),过滤本机外放的声音,
        // 适合会议中同时使用;必须在读取格式/装 tap 之前设置,否则格式会变。
        // 初始化失败时静默降级为普通录音,不打断听写(spec §7 同款思路)
        if SettingsStore.shared.filterLocalAudio {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                NSLog("OpenVoice: voice processing unavailable, falling back (%@)", error.localizedDescription)
            }
        }
        // VP 开启后 input node 上报的是虚拟聚合格式(多声道 deinterleaved),
        // 按它装 tap 会录到静音;必须用 nil 格式装 tap,转换器在回调里按
        // buffer 实际格式现建(实测验证)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: targetSampleRate,
                                               channels: 1,
                                               interleaved: true) else {
            throw NSError(domain: "AudioRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: tr("无法初始化音频转换。")])
        }
        converter = nil
        converterSourceSampleRate = 0

        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
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
        converterSourceSampleRate = 0

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
        converterSourceSampleRate = 0
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

        // VP 模式下 tap 给的是多声道 deinterleaved 聚合格式,直接交给
        // AVAudioConverter 会输出全零(实测);先抽第 0 声道拼成单声道
        // Float32 再转换。普通模式下声道数为 1,原样直通。
        let source: AVAudioPCMBuffer
        if buffer.format.channelCount == 1 {
            source = buffer
        } else {
            guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: buffer.format.sampleRate,
                                                 channels: 1, interleaved: false),
                  let mono = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                              frameCapacity: buffer.frameLength),
                  let dst = mono.floatChannelData?[0],
                  let srcCh = buffer.floatChannelData?[0] else { return }
            mono.frameLength = buffer.frameLength
            memcpy(dst, srcCh, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            source = mono
        }

        // 转换器按源格式采样率缓存(VP 开启前后格式不同)
        if converter == nil || converterSourceSampleRate != source.format.sampleRate {
            converter = AVAudioConverter(from: source.format, to: targetFormat)
            converterSourceSampleRate = source.format.sampleRate
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 64
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
            return source
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
