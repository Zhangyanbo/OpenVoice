import Foundation

/// 服务商类型与具体账户实例分离：同一服务商可以添加多个密钥，
/// 模型则通过 providerID 引用其中一个实例。
enum ModelProviderKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case openAI
    case google

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .google: return "Google"
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
        }
    }

    var apiKeyHelp: String {
        switch self {
        case .openAI:
            return tr("在 platform.openai.com 创建。Key 只保存在 macOS 钥匙串中，不写入配置文件，不进入日志。")
        case .google:
            return tr("在 Google AI Studio 创建。Key 只保存在 macOS 钥匙串中，不写入配置文件，不进入日志。")
        }
    }

    var apiKeyURL: URL {
        switch self {
        case .openAI:
            return URL(string: "https://platform.openai.com/api-keys")!
        case .google:
            return URL(string: "https://aistudio.google.com/api-keys")!
        }
    }

    var introduction: String {
        switch self {
        case .openAI:
            return tr("提供专用语音识别模型和 GPT 语言模型，转录准确、稳定。")
        case .google:
            return tr("使用 Gemini 多模态模型完成转录和后处理，兼顾成本、速度与多语言能力。")
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
}

struct ModelExecutionResult {
    var text: String
    var attempts: [ModelAttempt]
}

/// 路由器只依赖这个能力接口。新服务商只需实现客户端并在
/// ModelRouter.makeClient 中注册，有序回退与业务流程无需改动。
protocol ModelProviderClient {
    func transcribe(wav: Data, model: String, prompt: String?, language: String?) async throws -> String
    func chat(model: String, system: String, user: String, transcript: String) async throws -> String
}

struct ModelPreset: Identifiable, Equatable {
    let id: String
    let displayName: String
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
}
