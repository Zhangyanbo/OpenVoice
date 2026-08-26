import Foundation

/// 按用户排序依次尝试模型。每个模型都显式引用模型来源实例，
/// 因此加入新的云端或本地来源时，回退链本身不需改变。
enum ModelRouter {
    private enum AttemptError: LocalizedError {
        case timeout(String, Int)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .timeout(let model, let seconds):
                return tr("模型 %@ 在 %lld 秒内没有返回，已切换到下一个。", model, seconds)
            case .empty(let model): return tr("模型 %@ 没有返回文本，已切换到下一个。", model)
            }
        }
    }

    enum RouterError: LocalizedError {
        case noModels(ModelCapability)
        case allFailed(ModelCapability, String, [ModelAttempt])

        var attempts: [ModelAttempt] {
            switch self {
            case .noModels: return []
            case .allFailed(_, _, let attempts): return attempts
            }
        }

        var errorDescription: String? {
            switch self {
            case .noModels(.transcription):
                return tr("尚未配置语音识别模型。")
            case .noModels(.language):
                return tr("尚未配置语言模型。")
            case .allFailed(.transcription, let reason, _):
                return tr("所有语音识别模型均失败。最后一次错误：%@", reason)
            case .allFailed(.language, let reason, _):
                return tr("所有语言模型均失败。最后一次错误：%@", reason)
            }
        }
    }

    static func hasCredential(for models: [ConfiguredModel], providers: [ModelProvider]) -> Bool {
        models.contains { model in
            guard let provider = providers.first(where: { $0.id == model.providerID }) else { return false }
            return !provider.kind.requiresAPIKey
                || KeychainStore.loadAPIKey(providerID: model.providerID) != nil
        }
    }

    static func transcribe(
        wav: Data,
        models: [ConfiguredModel],
        providers: [ModelProvider],
        prompt: String?,
        language: String?,
        onFallback: (() async -> Void)? = nil
    ) async throws -> ModelExecutionResult {
        try await run(models: models, providers: providers, capability: .transcription,
                      onFallback: onFallback) { client, model in
            try await client.transcribe(wav: wav, model: model.modelID, prompt: prompt, language: language)
        }
    }

    static func chat(
        models: [ConfiguredModel],
        providers: [ModelProvider],
        system: String,
        user: String,
        transcript: String,
        onFallback: (() async -> Void)? = nil
    ) async throws -> ModelExecutionResult {
        try await run(models: models, providers: providers, capability: .language,
                      onFallback: onFallback) { client, model in
            try await client.chat(model: model.modelID, system: system, user: user, transcript: transcript)
        }
    }

    private static func run(
        models: [ConfiguredModel],
        providers: [ModelProvider],
        capability: ModelCapability,
        onFallback: (() async -> Void)?,
        operation: @escaping (any ModelProviderClient, ConfiguredModel) async throws -> String
    ) async throws -> ModelExecutionResult {
        guard !models.isEmpty else { throw RouterError.noModels(capability) }
        let timeoutSeconds = SettingsStore.shared.modelRequestTimeoutSeconds
        let timeoutNanoseconds = UInt64(timeoutSeconds) * 1_000_000_000
        var lastReason = tr("没有可用的模型来源或 API Key。")
        var attempts: [ModelAttempt] = []

        for (index, model) in models.enumerated() {
            let hasNextModel = index + 1 < models.count
            guard let provider = providers.first(where: { $0.id == model.providerID }) else {
                lastReason = tr("模型 %@ 引用的来源不存在。", model.displayName)
                attempts.append(attempt(model: model, providerName: tr("模型来源已移除"),
                                        capability: capability, succeeded: false, reason: lastReason))
                if hasNextModel { await onFallback?() }
                continue
            }
            let modelName = model.localizedDisplayName(providerKind: provider.kind,
                                                       capability: capability)
            guard !provider.kind.requiresAPIKey
                    || KeychainStore.loadAPIKey(providerID: provider.id) != nil else {
                lastReason = tr("%@ 尚未设置 API Key。", provider.name)
                attempts.append(attempt(model: model, providerName: provider.name,
                                        capability: capability, succeeded: false, reason: lastReason,
                                        modelName: modelName))
                if hasNextModel { await onFallback?() }
                continue
            }

            do {
                let client = try makeClient(for: provider)
                let text = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await operation(client, model) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        throw AttemptError.timeout(modelName, timeoutSeconds)
                    }
                    guard let result = try await group.next() else {
                        throw AttemptError.empty(modelName)
                    }
                    group.cancelAll()
                    return result
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AttemptError.empty(modelName)
                }
                attempts.append(attempt(model: model, providerName: provider.name,
                                        capability: capability, succeeded: true, reason: nil,
                                        modelName: modelName))
                return ModelExecutionResult(text: text, attempts: attempts)
            } catch {
                lastReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                attempts.append(attempt(model: model, providerName: provider.name,
                                        capability: capability, succeeded: false, reason: lastReason,
                                        modelName: modelName))
                NSLog("模型 %@（%@）请求失败，尝试下一个：%@",
                      model.modelID, provider.kind.rawValue, lastReason)
                if hasNextModel { await onFallback?() }
            }
        }

        throw RouterError.allFailed(capability, lastReason, attempts)
    }

    static func attempts(from error: Error) -> [ModelAttempt] {
        (error as? RouterError)?.attempts ?? []
    }

    private static func attempt(model: ConfiguredModel, providerName: String,
                                capability: ModelCapability, succeeded: Bool,
                                reason: String?, modelName: String? = nil) -> ModelAttempt {
        ModelAttempt(capability: capability,
                     providerName: providerName,
                     modelID: model.modelID,
                     modelName: modelName ?? model.displayName,
                     succeeded: succeeded,
                     failureReason: reason)
    }

    private static func makeClient(for provider: ModelProvider) throws -> any ModelProviderClient {
        switch provider.kind {
        case .openAI:
            guard let key = KeychainStore.loadAPIKey(providerID: provider.id) else {
                throw OpenAIClient.ClientError.noAPIKey
            }
            return OpenAIClient(apiKey: key)
        case .google:
            guard let key = KeychainStore.loadAPIKey(providerID: provider.id) else {
                throw GeminiClient.ClientError.noAPIKey
            }
            return GeminiClient(apiKey: key)
        case .ollama:
            return OllamaClient()
        case .appleIntelligence:
            return AppleIntelligenceClient()
        case .openCodeZen, .openCodeGo:
            guard let key = KeychainStore.loadAPIKey(providerID: provider.id) else {
                throw OpenCodeClient.ClientError.noAPIKey
            }
            return OpenCodeClient(providerID: provider.id, kind: provider.kind, apiKey: key)
        }
    }
}
