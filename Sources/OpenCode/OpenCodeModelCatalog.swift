import Foundation
import Combine

/// OpenCode 的模型并不共享同一种线上协议。目录中的 npm/provider 元数据
/// 决定实际请求路径；未知模型保守降级到 OpenAI-compatible Chat Completions。
enum OpenCodeTransport: String, Codable {
    case openAIChat
    case openAIResponses
    case anthropicMessages
    case googleGenerateContent

    var displayName: String {
        switch self {
        case .openAIChat: return tr("OpenAI 兼容")
        case .openAIResponses: return tr("Responses API")
        case .anthropicMessages: return tr("Anthropic Messages")
        case .googleGenerateContent: return tr("Gemini API")
        }
    }

    /// Anthropic Messages 没有音频内容块；其余三种协议由 OpenCode 网关
    /// 转发模型声明支持的 input_audio / inlineData。
    var canCarryAudio: Bool { self != .anthropicMessages }
}

struct OpenCodeCatalogModel: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var family: String?
    var transport: OpenCodeTransport
    var supportsAudioInput: Bool
    var inputCost: Double?
    var outputCost: Double?
    var status: String?
    var releaseDate: String?
    /// models.dev 明确声明的 effort 可选值；nil 表示目录未提供该能力信息。
    var reasoningEfforts: [String]? = nil
    /// models.dev 的 toggle 能力，适用于可关闭 thinking 的模型。
    var supportsReasoningToggle: Bool? = nil

    var canTranscribe: Bool { supportsAudioInput && transport.canCarryAudio }

    /// 选择模型明确支持的最低档；如果它只支持 high/max，则不主动设置。
    var lightReasoningEffort: String? {
        let values = reasoningEfforts ?? []
        return ["none", "minimal", "low"].first(where: values.contains)
    }

    var category: String {
        let value = "\(family ?? "") \(id) \(name)".lowercased()
        if value.contains("gpt") || value.contains("openai") { return "OpenAI" }
        if value.contains("claude") || value.contains("anthropic") { return "Anthropic" }
        if value.contains("gemini") || value.contains("google") { return "Google" }
        if value.contains("grok") || value.contains("xai") { return "xAI" }
        if value.contains("deepseek") { return "DeepSeek" }
        if value.contains("qwen") { return "Qwen" }
        if value.contains("kimi") { return "Kimi" }
        if value.contains("minimax") { return "MiniMax" }
        if value.contains("glm") { return "GLM" }
        if value.contains("mimo") { return "MiMo" }
        if value.contains("muse") { return "Muse" }
        if value.contains("nemotron") { return "NVIDIA" }
        return tr("其他")
    }

    var pricingText: String? {
        guard let inputCost, let outputCost else { return nil }
        if inputCost == 0, outputCost == 0 { return tr("免费") }
        return tr("输入 $%@ · 输出 $%@/百万 token",
                  Self.costString(inputCost), Self.costString(outputCost))
    }

    private static func costString(_ value: Double) -> String {
        if value >= 10 { return String(format: "%.0f", value) }
        if value >= 1 { return String(format: "%.2f", value) }
        return String(format: "%.3f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

/// 账号可见的 `/models` 与 models.opencode.ai 的协议/能力元数据合并后缓存。
/// 行为参考 OpenCode CLI：5 分钟内复用缓存，启动时和每小时后台刷新，
/// 设置页也提供强制刷新入口。失败时始终保留上一次成功目录。
@MainActor
final class OpenCodeModelCatalog: ObservableObject {
    static let shared = OpenCodeModelCatalog()

    private struct CachedProvider: Codable {
        var providerID: String
        var kind: ModelProviderKind
        var fetchedAt: Date
        var models: [OpenCodeCatalogModel]
    }

    private struct CacheFile: Codable {
        var schemaVersion: Int
        var providers: [CachedProvider]
    }

    @Published private(set) var catalogs: [String: [OpenCodeCatalogModel]] = [:]
    @Published private(set) var fetchedAt: [String: Date] = [:]
    @Published private(set) var refreshingProviderIDs: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]

    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private let ttl: TimeInterval = 5 * 60
    private let cacheURL = AppPaths.supportDirectory.appendingPathComponent("opencode-models.json")
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private init() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
              cache.schemaVersion == 1 else { return }
        for item in cache.providers where item.kind.isOpenCode {
            catalogs[item.providerID] = item.models
            fetchedAt[item.providerID] = item.fetchedAt
        }
    }

    func models(for provider: ModelProvider, capability: ModelCapability) -> [OpenCodeCatalogModel] {
        let available = catalogs[provider.id] ?? Self.fallbackModels(kind: provider.kind)
        return available
            .filter { $0.status?.lowercased() != "deprecated" }
            .filter { capability == .language || $0.canTranscribe }
            .sorted { lhs, rhs in
                if lhs.category != rhs.category { return lhs.category < rhs.category }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func model(providerID: String, kind: ModelProviderKind,
               modelID: String) -> OpenCodeCatalogModel {
        if let model = catalogs[providerID]?.first(where: { $0.id == modelID }) {
            return model
        }
        if let model = Self.fallbackModels(kind: kind).first(where: { $0.id == modelID }) {
            return model
        }
        return OpenCodeCatalogModel(id: modelID, name: modelID, family: nil,
                                    transport: .openAIChat, supportsAudioInput: false,
                                    inputCost: nil, outputCost: nil,
                                    status: nil, releaseDate: nil)
    }

    func isDeprecated(providerID: String, kind: ModelProviderKind, modelID: String) -> Bool {
        model(providerID: providerID, kind: kind, modelID: modelID)
            .status?.lowercased() == "deprecated"
    }

    func presets(for provider: ModelProvider, capability: ModelCapability) -> [ModelPreset] {
        models(for: provider, capability: capability).map { model in
            ModelPreset(id: model.id, displayName: model.name,
                        category: model.category,
                        detail: model.transport.displayName,
                        pricing: provider.kind == .openCodeGo
                            ? tr("OpenCode Go 订阅额度") : model.pricingText)
        }
    }

    func isRefreshing(_ providerID: String) -> Bool {
        refreshingProviderIDs.contains(providerID)
    }

    func refreshConfiguredProviders(force: Bool = false) {
        for provider in SettingsStore.shared.modelProviders where provider.kind.isOpenCode {
            refresh(provider: provider, force: force)
        }
    }

    func refresh(provider: ModelProvider, force: Bool = false) {
        guard provider.kind.isOpenCode,
              refreshTasks[provider.id] == nil,
              let key = KeychainStore.loadAPIKey(providerID: provider.id) else { return }
        if !force, let date = fetchedAt[provider.id], Date().timeIntervalSince(date) < ttl { return }

        refreshingProviderIDs.insert(provider.id)
        errors[provider.id] = nil
        refreshTasks[provider.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                refreshingProviderIDs.remove(provider.id)
                refreshTasks[provider.id] = nil
            }
            do {
                let models = try await Self.fetchCatalog(kind: provider.kind, apiKey: key,
                                                         session: session)
                guard !models.isEmpty else { throw CatalogError.empty }
                catalogs[provider.id] = models
                fetchedAt[provider.id] = Date()
                reconcileConfiguredModels(provider: provider, catalog: models)
                persist()
            } catch {
                errors[provider.id] = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// OpenCode 偶尔会让已废弃模型继续出现在 `/models` 中。只有目录明确标记
    /// deprecated 时才调整用户配置；MiMo 的已知换代保留原顺序原地迁移，
    /// 其他废弃项移除。未知或暂时缺失的模型一律保留。
    private func reconcileConfiguredModels(provider: ModelProvider,
                                           catalog: [OpenCodeCatalogModel]) {
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })

        func replacement(for modelID: String) -> String? {
            switch (provider.kind, modelID) {
            case (.openCodeGo, "mimo-v2-omni"): return "mimo-v2.5"
            case (.openCodeZen, "mimo-v2-omni"): return "mimo-v2.5-free"
            case (_, "mimo-v2-pro"): return "mimo-v2.5-pro"
            default: return nil
            }
        }

        func reconcile(_ configured: [ConfiguredModel], capability: ModelCapability)
            -> [ConfiguredModel] {
            var seen = Set<String>()
            return configured.compactMap { item in
                guard item.providerID == provider.id,
                      byID[item.modelID]?.status?.lowercased() == "deprecated" else {
                    let key = "\(item.providerID)\u{1f}\(item.modelID)"
                    return seen.insert(key).inserted ? item : nil
                }
                guard let replacementID = replacement(for: item.modelID),
                      let replacement = byID[replacementID],
                      replacement.status?.lowercased() != "deprecated",
                      capability == .language || replacement.canTranscribe else { return nil }
                let key = "\(item.providerID)\u{1f}\(replacementID)"
                guard seen.insert(key).inserted else { return nil }
                return ConfiguredModel(id: item.id, providerID: item.providerID,
                                       modelID: replacementID, displayName: replacement.name)
            }
        }

        let settings = SettingsStore.shared
        let transcription = reconcile(settings.transcriptionModels, capability: .transcription)
        let language = reconcile(settings.languageModels, capability: .language)
        if transcription != settings.transcriptionModels { settings.transcriptionModels = transcription }
        if language != settings.languageModels { settings.languageModels = language }
    }

    private func persist() {
        let providers = catalogs.compactMap { providerID, models -> CachedProvider? in
            guard let provider = SettingsStore.shared.modelProviders.first(where: { $0.id == providerID }),
                  provider.kind.isOpenCode else { return nil }
            return CachedProvider(providerID: providerID, kind: provider.kind,
                                  fetchedAt: fetchedAt[providerID] ?? Date(), models: models)
        }
        guard let data = try? JSONEncoder().encode(CacheFile(schemaVersion: 1, providers: providers)) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private enum CatalogError: LocalizedError {
        case badResponse
        case http(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .badResponse: return tr("OpenCode 返回了无法解析的模型目录。")
            case .http(let code): return tr("OpenCode 模型目录刷新失败（%lld）。", code)
            case .empty: return tr("OpenCode 当前没有返回可用模型。")
            }
        }
    }

    private nonisolated static func fetchCatalog(kind: ModelProviderKind, apiKey: String,
                                                  session: URLSession) async throws -> [OpenCodeCatalogModel] {
        guard let base = kind.openCodeAPIBase, let catalogID = kind.openCodeCatalogID else {
            throw CatalogError.badResponse
        }
        async let availableResult = fetchAvailableModels(base: base, apiKey: apiKey, session: session)
        async let metadataResult = try? fetchMetadata(catalogID: catalogID, session: session)
        let available = try await availableResult
        let metadata = await metadataResult ?? [:]
        let bundled = Dictionary(uniqueKeysWithValues: fallbackModels(kind: kind).map { ($0.id, $0) })

        return available.map { id, live in
            var model = metadata[id] ?? bundled[id] ?? live
            // `/models` 是账号实际可见列表；若它将来增加能力字段，优先采用。
            if live.supportsAudioInput { model.supportsAudioInput = true }
            if live.name != id { model.name = live.name }
            return model
        }
    }

    private nonisolated static func fetchAvailableModels(base: URL, apiKey: String,
                                                          session: URLSession) async throws
        -> [String: OpenCodeCatalogModel] {
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw CatalogError.http(http.statusCode) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { throw CatalogError.badResponse }

        var result: [String: OpenCodeCatalogModel] = [:]
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            let modalities = ((row["modalities"] as? [String: Any])?["input"] as? [String]) ?? []
            result[id] = OpenCodeCatalogModel(
                id: id,
                name: (row["name"] as? String) ?? id,
                family: row["family"] as? String,
                transport: transport(npm: nil, modelID: id),
                supportsAudioInput: modalities.contains("audio"),
                inputCost: nil,
                outputCost: nil,
                status: row["status"] as? String,
                releaseDate: (row["release_date"] as? String) ?? (row["created"] as? String)
            )
        }
        return result
    }

    private nonisolated static func fetchMetadata(catalogID: String, session: URLSession) async throws
        -> [String: OpenCodeCatalogModel] {
        let url = URL(string: "https://models.opencode.ai/api.json")!
        var request = URLRequest(url: url)
        request.setValue("OpenVoice/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = root[catalogID] as? [String: Any],
              let rows = provider["models"] as? [String: [String: Any]] else {
            throw CatalogError.badResponse
        }
        let providerNPM = provider["npm"] as? String
        var result: [String: OpenCodeCatalogModel] = [:]
        for (id, row) in rows {
            let override = row["provider"] as? [String: Any]
            let npm = (override?["npm"] as? String) ?? providerNPM
            let modalities = ((row["modalities"] as? [String: Any])?["input"] as? [String]) ?? []
            let cost = row["cost"] as? [String: Any]
            let reasoningOptions = row["reasoning_options"] as? [[String: Any]] ?? []
            let effortValues = reasoningOptions.first(where: {
                ($0["type"] as? String) == "effort"
            })?["values"] as? [String]
            let hasToggle = reasoningOptions.contains {
                ($0["type"] as? String) == "toggle"
            }
            result[id] = OpenCodeCatalogModel(
                id: id,
                name: (row["name"] as? String) ?? id,
                family: row["family"] as? String,
                transport: transport(npm: npm, modelID: id, catalogID: catalogID),
                supportsAudioInput: modalities.contains("audio"),
                inputCost: number(cost?["input"]),
                outputCost: number(cost?["output"]),
                status: row["status"] as? String,
                releaseDate: row["release_date"] as? String,
                reasoningEfforts: effortValues,
                supportsReasoningToggle: hasToggle
            )
        }
        return result
    }

    private nonisolated static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private nonisolated static func transport(npm: String?, modelID: String,
                                              catalogID: String? = nil) -> OpenCodeTransport {
        // Go 官方端点表将 Qwen / MiniMax 放在 /messages。当前 models.dev 的
        // 个别 Qwen 条目暂时继承了 provider 级 openai-compatible，需在这里纠正。
        if catalogID == "opencode-go",
           modelID.hasPrefix("qwen") || modelID.hasPrefix("minimax-") {
            return .anthropicMessages
        }
        switch npm {
        case let value? where value.contains("anthropic"): return .anthropicMessages
        case let value? where value.contains("google"): return .googleGenerateContent
        case "@ai-sdk/openai": return .openAIResponses
        case let value? where value.contains("openai-compatible"): return .openAIChat
        default:
            if modelID.hasPrefix("gpt-") || modelID.hasPrefix("grok-")
                || modelID.hasPrefix("muse-") { return .openAIResponses }
            if modelID.hasPrefix("claude-") || modelID.hasPrefix("qwen") { return .anthropicMessages }
            if modelID.hasPrefix("gemini-") { return .googleGenerateContent }
            return .openAIChat
        }
    }

    nonisolated static func fallbackPresets(kind: ModelProviderKind,
                                             capability: ModelCapability) -> [ModelPreset] {
        fallbackModels(kind: kind)
            .filter { capability == .language || $0.canTranscribe }
            .map {
                ModelPreset(id: $0.id, displayName: $0.name,
                            category: $0.category, detail: $0.transport.displayName,
                            pricing: kind == .openCodeGo ? tr("OpenCode Go 订阅额度") : $0.pricingText)
            }
    }

    private nonisolated static func fallbackModels(kind: ModelProviderKind) -> [OpenCodeCatalogModel] {
        func model(_ id: String, _ name: String, _ transport: OpenCodeTransport,
                   audio: Bool = false, free: Bool = false,
                   efforts: [String]? = nil, toggle: Bool = false) -> OpenCodeCatalogModel {
            OpenCodeCatalogModel(id: id, name: name, family: nil, transport: transport,
                                 supportsAudioInput: audio,
                                 inputCost: free ? 0 : nil, outputCost: free ? 0 : nil,
                                 status: nil, releaseDate: nil,
                                 reasoningEfforts: efforts,
                                 supportsReasoningToggle: toggle)
        }
        switch kind {
        case .openCodeZen:
            return [
                model("gpt-5.6-luna", "GPT 5.6 Luna", .openAIResponses, efforts: ["none", "low"]),
                model("gpt-5.6-terra", "GPT 5.6 Terra", .openAIResponses, efforts: ["none", "low"]),
                model("gpt-5.6-sol", "GPT 5.6 Sol", .openAIResponses, efforts: ["none", "low"]),
                model("gpt-5.5", "GPT 5.5", .openAIResponses),
                model("gpt-5.4-mini", "GPT 5.4 Mini", .openAIResponses),
                model("gpt-5-nano", "GPT 5 Nano", .openAIResponses),
                model("claude-fable-5", "Claude Fable 5", .anthropicMessages),
                model("claude-opus-5", "Claude Opus 5", .anthropicMessages),
                model("claude-sonnet-5", "Claude Sonnet 5", .anthropicMessages),
                model("claude-sonnet-4-6", "Claude Sonnet 4.6", .anthropicMessages),
                model("claude-haiku-4-5", "Claude Haiku 4.5", .anthropicMessages),
                model("gemini-3.7-flash", "Gemini 3.7 Flash", .googleGenerateContent,
                      audio: true, efforts: ["low"]),
                model("gemini-3.6-flash", "Gemini 3.6 Flash", .googleGenerateContent,
                      audio: true, efforts: ["minimal", "low"]),
                model("gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite", .googleGenerateContent,
                      audio: true, efforts: ["minimal", "low"]),
                model("grok-4.6", "Grok 4.6", .openAIResponses),
                model("grok-4.5", "Grok 4.5", .openAIResponses),
                model("muse-spark-1.2", "Muse Spark 1.2", .openAIResponses,
                      audio: true, efforts: ["minimal", "low"]),
                model("qwen3.7-max", "Qwen3.7 Max", .anthropicMessages, toggle: true),
                model("qwen3.7-plus", "Qwen3.7 Plus", .anthropicMessages, toggle: true),
                model("deepseek-v4-pro", "DeepSeek V4 Pro", .openAIChat),
                model("deepseek-v4-flash", "DeepSeek V4 Flash", .openAIChat),
                model("minimax-m3", "MiniMax M3", .openAIChat),
                model("glm-5.2", "GLM 5.2", .openAIChat),
                model("kimi-k3", "Kimi K3", .openAIChat),
                model("kimi-k2.7-code", "Kimi K2.7 Code", .openAIChat),
                model("big-pickle", "Big Pickle", .openAIChat, free: true),
                model("x-preview-f-free", "Ox Alpha Free", .openAIChat, free: true),
                model("mimo-v2.5-free", "MiMo-V2.5 Free", .openAIChat, audio: true, free: true),
                model("hy3-free", "Hy3 Free", .openAIChat, free: true),
                model("nemotron-3-ultra-free", "Nemotron 3 Ultra Free", .openAIChat, free: true),
                model("muse-spark-1.2-contributor-free", "Muse Spark 1.2 Contributor Free",
                      .openAIResponses, audio: true, free: true),
            ]
        case .openCodeGo:
            return [
                model("gpt-5.6-luna", "GPT 5.6 Luna", .openAIResponses, efforts: ["none", "low"]),
                model("grok-4.6", "Grok 4.6", .openAIResponses),
                model("glm-5.3", "GLM-5.3", .openAIChat),
                model("glm-5.2", "GLM-5.2", .openAIChat),
                model("glm-5.1", "GLM-5.1", .openAIChat),
                model("kimi-k3", "Kimi K3", .openAIChat),
                model("kimi-k2.7-code", "Kimi K2.7 Code", .openAIChat),
                model("kimi-k2.6", "Kimi K2.6", .openAIChat),
                model("longcat-2.0", "LongCat-2.0", .openAIChat),
                model("deepseek-v4-pro", "DeepSeek V4 Pro", .openAIChat),
                model("deepseek-v4-flash", "DeepSeek V4 Flash", .openAIChat),
                model("deepseek-v4-flash-vision-exp", "DeepSeek V4 Flash Vision Exp", .openAIChat),
                model("mimo-v2.5", "MiMo-V2.5", .openAIChat, audio: true),
                model("mimo-v2.5-pro", "MiMo-V2.5-Pro", .openAIChat, audio: true),
                model("minimax-m3", "MiniMax M3", .anthropicMessages, toggle: true),
                model("minimax-m2.7", "MiniMax M2.7", .anthropicMessages, toggle: true),
                model("qwen3.8-max", "Qwen3.8 Max", .anthropicMessages, toggle: true),
                model("qwen3.7-max", "Qwen3.7 Max", .anthropicMessages, toggle: true),
                model("qwen3.7-plus", "Qwen3.7 Plus", .anthropicMessages, toggle: true),
                model("qwen3.6-plus", "Qwen3.6 Plus", .anthropicMessages, toggle: true),
                model("hy3", "Hy3", .openAIChat),
                model("muse-spark-1.2-contributor", "Muse Spark 1.2 Contributor",
                      .openAIResponses, audio: true, efforts: ["minimal", "low"]),
                model("ox-alpha-free", "Ox Alpha Free", .openAIChat,
                      free: true, efforts: ["low"]),
            ]
        default:
            return []
        }
    }
}
