import Foundation

/// 服务商类型与具体账户实例分离：同一服务商可以添加多个密钥，
/// 模型则通过 providerID 引用其中一个实例。
enum ModelProviderKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
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
        }
    }

    var apiKeyHelp: String {
        switch self {
        case .openAI:
            return tr("在 platform.openai.com 创建。Key 只保存在 macOS 钥匙串中，不写入配置文件，不进入日志。")
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
