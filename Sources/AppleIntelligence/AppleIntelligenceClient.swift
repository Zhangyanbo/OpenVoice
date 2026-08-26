import AVFoundation
import Foundation
import FoundationModels
import Speech

/// Apple 本地模型的统一客户端：SpeechAnalyzer 负责语音转文字，
/// Foundation Models 负责转录后的整理和翻译。两者在界面上共享
/// Apple Intelligence 这一个模型来源，不经过网络服务商。
struct AppleIntelligenceClient: ModelProviderClient {
    static let speechModelID = "apple-speech-transcriber"
    static let languageModelID = "apple-intelligence"

    enum FoundationModelUnavailableReason {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unknown
    }

    enum ClientError: LocalizedError {
        case requiresMacOS26
        case unsupportedModel(String)
        case speechPermissionDenied
        case speechUnavailable
        case unsupportedLocale(String)
        case speechAssetsUnavailable
        case foundationModelUnavailable(FoundationModelUnavailableReason)

        var errorDescription: String? {
            switch self {
            case .requiresMacOS26:
                return tr("Apple Intelligence 模型需要 macOS 26 或更高版本。")
            case .unsupportedModel(let model):
                return tr("Apple Intelligence 不支持模型 %@。", model)
            case .speechPermissionDenied:
                return tr("未获得语音识别权限，请在系统设置中允许 OpenVoice 使用语音识别。")
            case .speechUnavailable:
                return tr("Apple 本地语音转录在这台 Mac 上不可用。")
            case .unsupportedLocale(let locale):
                return tr("Apple 本地语音转录不支持语言 %@。", locale)
            case .speechAssetsUnavailable:
                return tr("Apple 语音模型资源不可用或无法安装。")
            case .foundationModelUnavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return tr("这台 Mac 不支持 Apple Intelligence。")
                case .appleIntelligenceNotEnabled:
                    return tr("Apple Intelligence 尚未在系统设置中开启。")
                case .modelNotReady:
                    return tr("Apple Intelligence 模型尚未准备完成，请稍后重试。")
                case .unknown:
                    return tr("Apple Intelligence 当前不可用。")
                }
            }
        }
    }

    func transcribe(wav: Data, model: String, prompt: String?, language: String?) async throws -> String {
        guard model == Self.speechModelID else { throw ClientError.unsupportedModel(model) }
        guard #available(macOS 26.0, *) else { throw ClientError.requiresMacOS26 }
        return try await AppleIntelligenceRuntime.transcribe(
            wav: wav,
            language: language,
            contextualTerms: prompt
        )
    }

    func chat(model: String, system: String, user: String, transcript: String) async throws -> String {
        guard model == Self.languageModelID else { throw ClientError.unsupportedModel(model) }
        guard #available(macOS 26.0, *) else { throw ClientError.requiresMacOS26 }
        return try await AppleIntelligenceRuntime.respond(
            system: system,
            user: user,
            outputTokenLimit: min(4_096, OpenAIClient.outputTokenCeiling(forTranscript: transcript))
        )
    }
}

@available(macOS 26.0, *)
@Generable(description: "OpenVoice 可直接插入光标位置的最终文本")
private struct AppleDictationOutput {
    @Guide(description: "只包含整理或翻译后的正文，不包含介绍、解释、标签、引号、JSON 或 Markdown 代码块")
    var text: String
}

@available(macOS 26.0, *)
private enum AppleIntelligenceRuntime {
    static func transcribe(wav: Data, language: String?, contextualTerms: String?) async throws -> String {
        try await ensureSpeechAuthorization()
        guard SpeechTranscriber.isAvailable else {
            throw AppleIntelligenceClient.ClientError.speechUnavailable
        }

        let requestedLocale = speechLocale(for: language)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            throw AppleIntelligenceClient.ClientError.unsupportedLocale(
                requestedLocale.localizedString(forIdentifier: requestedLocale.identifier)
                    ?? requestedLocale.identifier
            )
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .transcription)
        try await installAssetsIfNeeded(for: transcriber)

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenVoice-AppleSpeech-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try wav.write(to: audioURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let audioFile = try AVAudioFile(forReading: audioURL)
        async let transcription = try transcriber.results.reduce(AttributedString()) { partial, result in
            partial + result.text
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let terms = contextualTerms?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try await analyzer.setContext(context)
        }
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let attributedText = try await transcription
        return String(attributedText.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func respond(system: String, user: String, outputTokenLimit: Int) async throws -> String {
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw AppleIntelligenceClient.ClientError.foundationModelUnavailable(
                unavailableReason(from: reason)
            )
        }

        // 通用提示词中的 JSON 要求是为云端 API schema 准备的。
        // Foundation Models 直接生成受约束的 Swift 类型，不应再让 text
        // 属性内嵌一层 JSON。
        let appleInstructions = system
            .replacingOccurrences(
                of: "- 以 JSON 输出，最终文本放在 text 字段中；text 里只有正文本身，不含任何解释或前后缀。",
                with: "- 将最终正文直接填入结构化输出的 text 属性；text 里只有正文本身，不含任何解释或前后缀。"
            )
            .replacingOccurrences(
                of: "- 以 JSON 输出，翻译后的最终文本放在 text 字段中；text 里只有正文本身，不含任何解释或前后缀。",
                with: "- 将翻译后的最终正文直接填入结构化输出的 text 属性；text 里只有正文本身，不含任何解释或前后缀。"
            ) + """

        响应格式由系统的结构化生成约束负责。将最终正文直接填入 text 属性；
        text 内不得再包含 JSON、Markdown 代码块、引号、说明或“下面是…”之类的前缀。
        """
        let session = LanguageModelSession(model: model, instructions: appleInstructions)
        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: outputTokenLimit
        )
        let response = try await session.respond(
            to: user,
            generating: AppleDictationOutput.self,
            options: options
        )
        return response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ensureSpeechAuthorization() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus)
                }
            }
        }
        guard status == .authorized else {
            throw AppleIntelligenceClient.ClientError.speechPermissionDenied
        }
    }

    private static func unavailableReason(
        from reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> AppleIntelligenceClient.FoundationModelUnavailableReason {
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
        case .modelNotReady: return .modelNotReady
        @unknown default: return .unknown
        }
    }

    private static func speechLocale(for language: String?) -> Locale {
        guard let language, language != "auto", !language.isEmpty else {
            return Locale.current
        }
        return Locale(identifier: language)
    }

    private static func installAssetsIfNeeded(for transcriber: SpeechTranscriber) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .unsupported:
            throw AppleIntelligenceClient.ClientError.speechAssetsUnavailable
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) else {
                throw AppleIntelligenceClient.ClientError.speechAssetsUnavailable
            }
            try await request.downloadAndInstall()
        @unknown default:
            throw AppleIntelligenceClient.ClientError.speechAssetsUnavailable
        }
    }
}
