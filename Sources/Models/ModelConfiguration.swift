import Foundation

/// 模型来源类型与具体实例分离：同一云端来源可以添加多个密钥，
/// 本地来源则无需凭据。模型通过 providerID 引用其中一个实例。
enum ModelProviderKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case openAI
    case google
    case ollama
    case appleIntelligence
    case openCodeZen
    case openCodeGo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .google: return "Google"
        case .ollama: return "Ollama"
        case .appleIntelligence: return "Apple Intelligence"
        case .openCodeZen: return "OpenCode Zen"
        case .openCodeGo: return "OpenCode Go"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .ollama, .appleIntelligence: return false
        default: return true
        }
    }

    var isOpenCode: Bool {
        self == .openCodeZen || self == .openCodeGo
    }

    var openCodeCatalogID: String? {
        switch self {
        case .openCodeZen: return "opencode"
        case .openCodeGo: return "opencode-go"
        default: return nil
        }
    }

    var openCodeAPIBase: URL? {
        switch self {
        case .openCodeZen: return URL(string: "https://opencode.ai/zen/v1")
        case .openCodeGo: return URL(string: "https://opencode.ai/zen/go/v1")
        default: return nil
        }
    }

    func presets(for capability: ModelCapability) -> [ModelPreset] {
        switch (self, capability) {
        case (.openAI, .transcription):
            return [
                ModelPreset(id: "gpt-4o-transcribe", displayName: "GPT-4o transcribe"),
                ModelPreset(id: "whisper-1", displayName: "whisper-1"),
                ModelPreset(id: "gpt-4o-mini-transcribe", displayName: "GPT-4o mini transcribe"),
            ]
        case (.openAI, .language):
            return [
                ModelPreset(id: SettingsStore.defaultLLMModel, displayName: SettingsStore.defaultLLMModel),
                ModelPreset(id: "gpt-5-nano", displayName: "gpt-5-nano"),
                ModelPreset(id: "gpt-4.1-nano", displayName: "gpt-4.1-nano"),
                ModelPreset(id: "gpt-5.4-mini", displayName: "gpt-5.4-mini"),
            ]
        case (.google, .transcription):
            return [
                ModelPreset(id: "gemini-3.5-flash-lite", displayName: "Gemini 3.5 Flash-Lite"),
                ModelPreset(id: "gemini-3.6-flash", displayName: "Gemini 3.6 Flash"),
            ]
        case (.google, .language):
            return [
                ModelPreset(id: "gemini-3.5-flash-lite", displayName: "Gemini 3.5 Flash-Lite"),
                ModelPreset(id: "gemini-3.6-flash", displayName: "Gemini 3.6 Flash"),
                ModelPreset(id: "gemini-3.7-flash", displayName: "Gemini 3.7 Flash"),
            ]
        case (.ollama, .transcription), (.ollama, .language):
            // Gemma 4 的 QAT 版本更适合 16 GB 机器；暂时只开放这两个经过
            // 音频输入验证的轻量型号，不把 Ollama 的完整目录暴露给用户。
            return [
                ModelPreset(id: "gemma4:e2b-it-qat", displayName: "Gemma 4 E2B (QAT)"),
                ModelPreset(id: "gemma4:e4b-it-qat", displayName: "Gemma 4 E4B (QAT)"),
            ]
        case (.appleIntelligence, .transcription):
            return [
                ModelPreset(
                    id: AppleIntelligenceClient.speechModelID,
                    displayName: tr("Apple 语音转录"),
                    detail: tr("使用 macOS 26 内置语音模型；自动识别时跟随系统语言")
                ),
            ]
        case (.appleIntelligence, .language):
            return [
                ModelPreset(
                    id: AppleIntelligenceClient.languageModelID,
                    displayName: "Apple Intelligence",
                    detail: tr("使用 macOS 26 内置基础模型整理或翻译文字")
                ),
            ]
        case (.openCodeZen, _), (.openCodeGo, _):
            return OpenCodeModelCatalog.fallbackPresets(kind: self, capability: capability)
        }
    }

    /// 首次添加服务商时自动写入的模型组合。这与可选模型目录分开，
    /// 新服务商（如 Gemini）必须各自定义，欢迎引导无需知道具体模型。
    func defaultPresets(for capability: ModelCapability) -> [ModelPreset] {
        switch (self, capability) {
        case (.openAI, .transcription):
            return Array(presets(for: capability).prefix(2))
        case (.openAI, .language):
            return Array(presets(for: capability).prefix(1))
        case (.google, .transcription), (.google, .language):
            // Flash-Lite 先处理低成本轻任务，较强的 Flash 只在失败时兜底。
            return Array(presets(for: capability).prefix(2))
        case (.ollama, .transcription), (.ollama, .language):
            // 首次添加只启用更轻的 E2B；E4B 可在设置中手动加入回退链。
            return Array(presets(for: capability).prefix(1))
        case (.appleIntelligence, .transcription), (.appleIntelligence, .language):
            // Apple Intelligence 只在设置页由用户手动加入，不自动改变现有模型链。
            return []
        case (.openCodeZen, .transcription):
            return presets(for: capability).filter {
                ["gemini-3.5-flash-lite", "mimo-v2.5-free"].contains($0.id)
            }
        case (.openCodeZen, .language):
            return presets(for: capability).filter {
                [SettingsStore.defaultLLMModel, "mimo-v2.5-free"].contains($0.id)
            }
        case (.openCodeGo, .transcription):
            return presets(for: capability).filter { $0.id == "mimo-v2.5" }
        case (.openCodeGo, .language):
            return presets(for: capability).filter {
                [SettingsStore.defaultLLMModel, "mimo-v2.5", "ox-alpha-free"].contains($0.id)
            }
        }
    }

    var apiKeyHelp: String? {
        switch self {
        case .openAI:
            return tr("在 platform.openai.com 创建。Key 只保存在 macOS 钥匙串中，不写入配置文件，不进入日志。")
        case .google:
            return tr("在 Google AI Studio 创建。Key 只保存在 macOS 钥匙串中，不写入配置文件，不进入日志。")
        case .ollama:
            return nil
        case .appleIntelligence:
            return nil
        case .openCodeZen, .openCodeGo:
            return tr("在 opencode.ai 获取。Key 只保存在 macOS 钥匙串中，不写入配置文件，不进入日志。")
        }
    }

    var apiKeyURL: URL? {
        switch self {
        case .openAI:
            return URL(string: "https://platform.openai.com/api-keys")!
        case .google:
            return URL(string: "https://aistudio.google.com/api-keys")!
        case .ollama:
            return nil
        case .appleIntelligence:
            return nil
        case .openCodeZen, .openCodeGo:
            return URL(string: "https://opencode.ai/auth")!
        }
    }

    var introduction: String {
        switch self {
        case .openAI:
            return tr("提供专用语音识别模型和 GPT 语言模型，转录准确、稳定。")
        case .google:
            return tr("使用 Gemini 多模态模型完成转录和后处理，兼顾成本、速度与多语言能力。")
        case .ollama:
            return tr("通过本机 Ollama 运行模型，无需 API Key。请先在 Ollama 中下载所选模型。")
        case .appleIntelligence:
            return tr("在 macOS 26 上使用 Apple 的本地语音转录和 Apple Intelligence 整理文字；无需 API Key。")
        case .openCodeZen:
            return tr("按量使用 OpenCode 精选模型；模型目录会自动更新，并按各模型的原生协议分流。")
        case .openCodeGo:
            return tr("使用 OpenCode Go 订阅额度；模型目录会自动更新，并在额度限制内按顺序回退。")
        }
    }

    /// 设置界面只显示服务商的标准 API 价。转录按实际计费口径展示：
    /// OpenAI 使用官方分钟估价；Gemini 依照 32 audio tokens/s 换算输入成本。
    func pricingSummary(for modelID: String, capability: ModelCapability) -> String? {
        switch (self, capability, modelID) {
        case (.openAI, .transcription, "gpt-4o-transcribe"),
             (.openAI, .transcription, "whisper-1"):
            return tr("$%@/千分钟", "6.00")
        case (.openAI, .transcription, "gpt-4o-mini-transcribe"):
            return tr("$%@/千分钟", "3.00")
        case (.google, .transcription, "gemini-3.5-flash-lite"):
            return tr("$%@/千分钟", "0.58")
        case (.google, .transcription, "gemini-3.6-flash"):
            return tr("$%@/千分钟", "1.44")

        case (.openAI, .language, "gpt-5.6-luna"):
            return tr("输入 $%@ · 输出 $%@/百万 token", "0.20", "1.20")
        case (.openAI, .language, "gpt-5-nano"):
            return tr("输入 $%@ · 输出 $%@/百万 token", "0.05", "0.40")
        case (.openAI, .language, "gpt-4.1-nano"):
            return tr("输入 $%@ · 输出 $%@/百万 token", "0.10", "0.40")
        case (.openAI, .language, "gpt-5.4-mini"):
            return tr("输入 $%@ · 输出 $%@/百万 token", "0.75", "4.50")
        case (.google, .language, "gemini-3.5-flash-lite"):
            return tr("输入 $%@ · 输出 $%@/百万 token", "0.30", "2.50")
        case (.google, .language, "gemini-3.6-flash"),
             (.google, .language, "gemini-3.7-flash"):
            return tr("输入 $%@ · 输出 $%@/百万 token", "0.75", "3.75")
        case (.ollama, _, _):
            return tr("本地运行")
        case (.appleIntelligence, _, _):
            return tr("本地运行")
        case (.openCodeZen, _, _):
            return tr("OpenCode Zen 按量计费")
        case (.openCodeGo, _, _):
            return tr("OpenCode Go 订阅额度")
        default:
            return nil
        }
    }
}

enum ModelCapability: String, Codable, Identifiable {
    case transcription
    case language

    var id: String { rawValue }
}

/// 一次路由尝试的持久化摘要。只记录服务商、模型和结果，
/// 不包含 API Key、请求正文或其他敏感信息。
struct ModelAttempt: Codable, Equatable, Identifiable {
    var id = UUID()
    var capability: ModelCapability
    var providerName: String
    var modelID: String
    var modelName: String
    var succeeded: Bool
    var failureReason: String?

    /// 历史记录中会保留当时的显示名。Apple 模型名由稳定 ID 动态本地化，
    /// 因此旧记录也能立即跟随界面语言。
    var localizedModelName: String {
        switch modelID {
        case AppleIntelligenceClient.speechModelID: return tr("Apple 语音转录")
        case AppleIntelligenceClient.languageModelID: return "Apple Intelligence"
        default: return modelName
        }
    }
}

struct ModelExecutionResult {
    var text: String
    var attempts: [ModelAttempt]
}

/// 路由器只依赖这个能力接口。新服务商只需实现客户端并在
/// ModelRouter.makeClient 中注册，有序回退与业务流程无需改动。
protocol ModelProviderClient {
    func transcribe(wav: Data, model: String, prompt: String?, language: String?) async throws -> String
    func chat(model: String, system: String, user: String) async throws -> String
}

struct ModelPreset: Identifiable, Equatable {
    let id: String
    let displayName: String
    var category: String? = nil
    var detail: String? = nil
    var pricing: String? = nil
}

struct ModelProvider: Codable, Identifiable, Equatable {
    static let defaultOpenAIID = "openai-default"

    var id: String
    var kind: ModelProviderKind
    var name: String

    static let defaultOpenAI = ModelProvider(
        id: defaultOpenAIID,
        kind: .openAI,
        name: "OpenAI"
    )
}

struct ConfiguredModel: Codable, Identifiable, Equatable {
    var id: String
    var providerID: String
    var modelID: String
    var displayName: String

    init(id: String = UUID().uuidString, providerID: String, modelID: String, displayName: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName ?? modelID
    }

    /// Apple 内置模型的旧配置可能已经持久化了某一种界面语言的名称。
    /// 显示时按稳定 model ID 重新本地化，不改写用户数据，也兼容旧版配置。
    func localizedDisplayName(providerKind: ModelProviderKind?, capability: ModelCapability) -> String {
        guard providerKind == .appleIntelligence else { return displayName }
        return ModelProviderKind.appleIntelligence.presets(for: capability)
            .first(where: { $0.id == modelID })?.displayName ?? displayName
    }
}
