import Foundation
import AppKit

/// 记录上次实际发送给 OpenAI 的上下文与术语提示,供"查看本次发送的上下文"(spec §18)。
final class LastRequestLog: ObservableObject {
    static let shared = LastRequestLog()
    @Published var contextSummary: String = "(还没有发送过请求)"
    @Published var termHint: String = ""
    @Published var timestamp: Date?
    /// 最近一次失败的完整错误信息(悬浮条上只显示截断版)
    @Published var lastError: String?
    @Published var lastErrorAt: Date?
    /// 最近一次文字插入的决策轨迹(AX/粘贴路径,由 TextInserter 写入)
    @Published var insertTrace: String = ""
}

/// 核心状态机:idle → recording → transcribing → idle。
/// 所有模块在此编排。上下文/术语表都是可选增强,任何一环失败都不阻断主流程(spec §7–8)。
final class DictationController {
    enum Mode {
        case dictation
        case translation(target: String)
    }

    enum State {
        case idle
        case recording(Mode)
        case transcribing
    }

    private(set) var state: State = .idle

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private let settings = SettingsStore.shared
    private let glossary = GlossaryStore.shared
    private let recorder = AudioRecorder()
    private let panel = FloatingPanelController()
    let autoLearner = AutoLearner()

    /// 转录失败时保留的录音,重试后或成功后即丢弃(spec §19)
    private struct FailedAttempt {
        let wav: Data
        let mode: Mode
        let context: DictationContext
        let target: InsertionTarget?
    }
    private var failedAttempt: FailedAttempt?

    private var session: (mode: Mode, context: DictationContext, target: InsertionTarget?)?

    init() {
        recorder.onLevel = { [weak self] level in
            self?.panel.updateLevel(level)
        }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onRetry = { [weak self] in self?.retry() }
        panel.onDismissError = { [weak self] in
            self?.failedAttempt = nil
            self?.panel.hide()
        }
        panel.onLanguageChange = { [weak self] language in
            guard let self, case .recording(.translation) = self.state else { return }
            self.state = .recording(.translation(target: language))
            if var s = self.session {
                s.mode = .translation(target: language)
                self.session = s
            }
        }
    }

    // MARK: - 入口

    func toggleDictation() {
        switch state {
        case .idle: start(mode: .dictation)
        case .recording: finish()
        case .transcribing: break
        }
    }

    func toggleTranslation() {
        switch state {
        case .idle: start(mode: .translation(target: settings.defaultTargetLanguage))
        case .recording: finish()
        case .transcribing: break
        }
    }

    func cancel() {
        switch state {
        case .recording:
            recorder.cancel()
            state = .idle
            session = nil
            panel.hide()
        case .transcribing, .idle:
            break
        }
    }

    // MARK: - 流程

    private func start(mode: Mode) {
        guard KeychainStore.loadAPIKey() != nil else {
            showKeyAlert()
            return
        }
        guard Permissions.accessibilityGranted else {
            Permissions.showAccessibilityAlert()
            return
        }
        Permissions.requestMicrophone { [weak self] granted in
            guard let self else { return }
            guard granted else {
                Permissions.showMicrophoneAlert()
                return
            }
            self.reallyStart(mode: mode)
        }
    }

    private func reallyStart(mode: Mode) {
        guard case .idle = state else { return }
        failedAttempt = nil
        autoLearner.cancelObservation()

        // 在录音开始的瞬间采集上下文与插入目标(spec §5, §14)
        let (context, target) = AXContextReader.capture(settings: settings)
        session = (mode, context, target)

        do {
            try recorder.start()
        } catch {
            session = nil
            showError("无法开始录音:\(error.localizedDescription)")
            return
        }

        state = .recording(mode)
        // 开始只响一声:提示音优先,关掉提示音后按键音仍可提供反馈
        if settings.playSound {
            SoundPlayer.playStart()
        } else if settings.keyPressSound {
            SoundPlayer.playKeyClick()
        }
        if settings.showPanel {
            switch mode {
            case .dictation:
                panel.showListening(translation: nil)
            case .translation(let target):
                panel.showListening(translation: (target, settings.targetLanguages))
            }
        }
    }

    private func finish() {
        guard case .recording = state, let session else { return }
        // 语言可能在悬浮条上被临时切换,以 controller 记录的最新 mode 为准
        let mode: Mode
        if case .recording(let m) = state { mode = m } else { mode = session.mode }

        guard let wav = recorder.stop() else {
            // 录音太短,当作取消
            state = .idle
            self.session = nil
            panel.hide()
            return
        }

        if settings.keyPressSound { SoundPlayer.playKeyClick() }
        state = .transcribing
        panel.showTranscribing()
        process(wav: wav, mode: mode, context: session.context, target: session.target)
        self.session = nil
    }

    private func retry() {
        guard let attempt = failedAttempt, case .idle = state else { return }
        failedAttempt = nil
        state = .transcribing
        panel.showTranscribing()
        process(wav: attempt.wav, mode: attempt.mode, context: attempt.context, target: attempt.target)
    }

    private func process(wav: Data, mode: Mode, context: DictationContext, target: InsertionTarget?) {
        let termHint = glossary.promptHint()
        let recognitionLanguage = settings.recognitionLanguage
        let transcribeModel = settings.effectiveTranscribeModel
        let llmModel = settings.effectiveLLMModel

        LastRequestLog.shared.contextSummary = context.summary
        LastRequestLog.shared.termHint = termHint.isEmpty ? "(无)" : termHint
        LastRequestLog.shared.timestamp = Date()

        // controller 与应用同生命周期,请求期间强持有以保证结果送达
        Task {
            do {
                let client = try OpenAIClient.fromKeychain()
                let raw = try await client.transcribe(wav: wav,
                                                      model: transcribeModel,
                                                      prompt: termHint.isEmpty ? nil : termHint,
                                                      language: recognitionLanguage)
                guard !raw.isEmpty else {
                    await MainActor.run { self.finishEmpty() }
                    return
                }

                // 轻量语言模型整理
                var final = raw
                do {
                    final = try await client.chat(model: llmModel,
                                                  system: Self.systemPrompt(mode: mode, context: context, terms: termHint),
                                                  user: Self.userPrompt(mode: mode, context: context, transcript: raw))
                    if final.isEmpty { final = raw }
                } catch {
                    // 只有普通听写且无选中文字时才可安全降级为原始转录;
                    // 翻译模式降级会插入未翻译文本,选中文字指令模式降级会用指令原文
                    // 覆盖用户选中的内容 —— 这两种情况一律走失败+重试(spec §19)
                    var canFallbackToRaw = false
                    if case .dictation = mode, context.selectedText == nil { canFallbackToRaw = true }
                    guard canFallbackToRaw else {
                        await MainActor.run {
                            self.transcriptionFailed(wav: wav, mode: mode, context: context,
                                                     target: target, error: error)
                        }
                        return
                    }
                    NSLog("整理模型失败,使用原始转录: \(error.localizedDescription)")
                }

                let text = final
                await MainActor.run { self.insert(text: text, target: target, mode: mode, context: context) }
            } catch {
                await MainActor.run {
                    self.transcriptionFailed(wav: wav, mode: mode, context: context,
                                             target: target, error: error)
                }
            }
        }
    }

    private func insert(text: String, target: InsertionTarget?, mode: Mode, context: DictationContext) {
        state = .idle
        if settings.keepHistory {
            let modeLabel: String
            switch mode {
            case .dictation: modeLabel = "语音"
            case .translation(let language): modeLabel = "翻译 → \(language)"
            }
            HistoryStore.shared.add(text: text, mode: modeLabel, appName: context.appName)
        }
        // 转录已结束,先收起悬浮条;粘贴路径的剪贴板恢复还要延迟一会儿,不必让用户等
        panel.hide()
        TextInserter.insert(text, target: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .inserted(let method):
                if method == .accessibility, let element = target?.element {
                    self.autoLearner.beginObservation(element: element, insertedText: text)
                } else if method == .paste, let element = target?.element {
                    // 粘贴路径也尝试观察(拿得到 AXValue 才会生效)
                    self.autoLearner.beginObservation(element: element, insertedText: text)
                }
            case .copiedToClipboardOnly:
                ToastPanel.show(message: "无法自动输入,结果已复制到剪贴板。")
            }
        }
    }

    private func finishEmpty() {
        state = .idle
        panel.hide()
    }

    private func transcriptionFailed(wav: Data, mode: Mode, context: DictationContext,
                                     target: InsertionTarget?, error: Error) {
        state = .idle
        failedAttempt = FailedAttempt(wav: wav, mode: mode, context: context, target: target)
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        NSLog("转录失败: \(reason)")
        LastRequestLog.shared.lastError = reason
        LastRequestLog.shared.lastErrorAt = Date()
        panel.showError("转录失败:\(reason)")
    }

    // MARK: - Prompt 组装(spec §3, §8, §13)

    static func systemPrompt(mode: Mode, context: DictationContext, terms: String) -> String {
        var lines: [String] = []
        switch mode {
        case .dictation:
            lines.append("""
            你是一个语音输入法的后处理器。用户通过语音说出了一段文字,你要把语音转录结果整理成可以直接插入光标位置的最终文本。
            规则:
            - 删除“呃”“嗯”等填充词、无意义重复;用户说话中途自我纠正时,只保留纠正后的内容。
            - 补全标点、修正大小写、规范数字与列表格式。
            - 保持用户的原意、语气和用词。只修正语音表达带来的噪声,绝不替用户重新写作或扩写。
            - 输出语言与用户说话的语言一致。
            - 只输出最终文本本身,不要任何解释、引号或前后缀。
            """)
            if context.selectedText != nil {
                lines.append("""
                特殊情况:用户当前选中了一段文字(见下文)。如果转录内容是对这段文字的操作指令(例如“把这个写短一点”“翻译成中文”“整理成列表”),则输出对选中文字执行该指令后的结果,用于直接替换选中文字;否则按普通语音输入处理,输出整理后的转录文本。
                """)
            }
        case .translation(let target):
            lines.append("""
            你是一个语音翻译输入法的后处理器。用户说了一段话,你要输出它的\(target)版本,用于直接插入光标位置。
            规则:
            - 不要逐字机器翻译,直接生成自然、地道的\(target)表达。
            - 保持原意、人名、专有名词、技术术语、数字、格式和语气。
            - 删除“呃”“嗯”等填充词和无意义重复;用户自我纠正时只保留纠正后的内容。
            - 只输出翻译后的最终文本,不要任何解释、引号或前后缀。
            """)
        }
        if !terms.isEmpty {
            lines.append("用户的个人术语表(专有名词以此为准的拼写/大小写):\(terms)")
        }
        return lines.joined(separator: "\n\n")
    }

    static func userPrompt(mode: Mode, context: DictationContext, transcript: String) -> String {
        var lines: [String] = []
        if !context.isEmpty {
            var contextLines: [String] = []
            if let app = context.appName { contextLines.append("当前 App:\(app)") }
            if let title = context.windowTitle { contextLines.append("窗口标题:\(title)") }
            if let selected = context.selectedText { contextLines.append("当前选中的文字:「\(selected)」") }
            if let before = context.beforeCursor { contextLines.append("光标前的文字:…\(before)") }
            if let after = context.afterCursor { contextLines.append("光标后的文字:\(after)…") }
            lines.append("上下文(仅供判断语言、风格、术语拼写,不要在输出中重复它):\n" + contextLines.joined(separator: "\n"))
        }
        lines.append("语音转录结果:\n\(transcript)")
        return lines.joined(separator: "\n\n")
    }

    // MARK: - 错误提示

    private func showKeyAlert() {
        let alert = NSAlert()
        alert.messageText = "尚未设置 OpenAI API Key。"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NotificationCenter.default.post(name: .openSettingsRequest, object: nil)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension Notification.Name {
    static let openSettingsRequest = Notification.Name("openSettingsRequest")
}
