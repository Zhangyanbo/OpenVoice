import Foundation
import AppKit
import Combine
import ServiceManagement

/// 所有用户设置的唯一入口,UserDefaults 持久化。
/// 模型名等默认值只在这里定义,其他代码不得硬编码。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    static let defaultTranscribeModel = "gpt-4o-transcribe"
    static let defaultLLMModel = "gpt-5.6-luna"
    static let defaultModelRequestTimeoutSeconds = 30
    static let modelRequestTimeoutOptions = [15, 30, 60, 120]
    static let defaultTranscriptionHistoryRetentionDays = 7
    static let transcriptionHistoryRetentionDayOptions = [1, 3, 7, 14, 30, 90]
    static let defaultRetainedRecordingCount = 10
    static let retainedRecordingCountOptions = [0, 5, 10, 20, 50, 100]
    /// 模型配置只保存稳定引用；动态目录与协议元数据另存为可丢弃缓存。
    private static let modelConfigurationSchemaVersion = 2

    /// 界面语言。跟随系统时由系统首选语言决定。
    enum AppLanguage: String, CaseIterable, Identifiable {
        case system
        case zhHans = "zh-Hans"
        case en = "en"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return tr("跟随系统")
            case .zhHans: return "中文"
            case .en: return "English"
            }
        }
    }

    /// 界面外观。跟随系统时由系统深浅色决定。
    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return tr("跟随系统")
            case .light: return tr("浅色")
            case .dark: return tr("深色")
            }
        }

        /// 对应的 macOS 外观名;.system 时返回 nil 表示不干预
        var nsAppearanceName: NSAppearance.Name? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance.Name.aqua
            case .dark: return NSAppearance.Name.darkAqua
            }
        }
    }

    /// 可作为主/备用快捷键的按键。修饰键通过 flagsChanged 捕获,F 键通过 keyDown 捕获。
    enum TriggerKey: String, CaseIterable, Identifiable {
        case none
        case fn
        case rightCommand
        case rightOption
        case f13
        case f14

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none: return tr("无")
            case .fn: return "Fn"
            case .rightCommand: return tr("右 Command")
            case .rightOption: return tr("右 Option")
            case .f13, .f14: return displayNameRaw
            }
        }

        private var displayNameRaw: String {
            switch self {
            case .f13: return "F13"
            case .f14: return "F14"
            default: return ""
            }
        }

        /// 硬件 keyCode;修饰键与 F 键分别处理
        var keyCode: Int64? {
            switch self {
            case .none: return nil
            case .fn: return 63
            case .rightCommand: return 54
            case .rightOption: return 61
            case .f13: return 105
            case .f14: return 107
            }
        }

        var isModifier: Bool {
            switch self {
            case .fn, .rightCommand, .rightOption: return true
            default: return false
            }
        }
    }

    /// 编辑力度:整理模型对转录文本的改写程度
    enum EditingEffort: String, CaseIterable, Identifiable {
        case low, medium, high

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .low: return tr("低")
            case .medium: return tr("中")
            case .high: return tr("高")
            }
        }
    }

    /// 结构化程度:输出文本的组织形式
    enum FormatLevel: String, CaseIterable, Identifiable {
        case plain, medium, rich

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .plain: return tr("低")
            case .medium: return tr("中")
            case .rich: return tr("高")
            }
        }
    }

    private let defaults = UserDefaults.standard

    // MARK: - 语言
    @Published var appLanguage: AppLanguage { didSet { defaults.set(appLanguage.rawValue, forKey: "appLanguage") } }
    /// 外观模式。切换时立即应用到整个应用(NSApp.appearance),logo 随深浅色自动黑白切换。
    @Published var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    /// 把当前外观模式应用到整个应用;启动时也需手动调用一次(init 不触发 didSet)
    func applyAppearance() {
        NSApp?.appearance = appearanceMode.nsAppearanceName.flatMap { NSAppearance(named: $0) }
    }

    // MARK: - 个性化
    @Published var editingEffort: EditingEffort { didSet { defaults.set(editingEffort.rawValue, forKey: "editingEffort") } }
    @Published var formatLevel: FormatLevel { didSet { defaults.set(formatLevel.rawValue, forKey: "formatLevel") } }

    // MARK: - 通用
    /// 唯一的音效总开关:关掉后任何情况下都不出声
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published var showPanel: Bool { didSet { defaults.set(showPanel, forKey: "showPanel") } }
    /// 过滤本机声音(AVAudioEngine Voice Processing):开会后/会议中避免录进电脑外放
    @Published var filterLocalAudio: Bool { didSet { defaults.set(filterLocalAudio, forKey: "filterLocalAudio") } }
    /// 单个模型尝试的等待上限；超时后 ModelRouter 自动进入下一项。
    @Published var modelRequestTimeoutSeconds: Int {
        didSet { defaults.set(modelRequestTimeoutSeconds, forKey: "modelRequestTimeoutSeconds") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin()
        }
    }

    // MARK: - 快捷键
    @Published var primaryKey: TriggerKey { didSet { defaults.set(primaryKey.rawValue, forKey: "primaryKey") } }
    @Published var altKey: TriggerKey { didSet { defaults.set(altKey.rawValue, forKey: "altKey") } }

    // MARK: - 语言
    /// "auto" 或 ISO 639-1 码
    @Published var recognitionLanguage: String { didSet { defaults.set(recognitionLanguage, forKey: "recognitionLanguage") } }
    /// 翻译目标语言列表,第一项为默认
    @Published var targetLanguages: [String] { didSet { defaults.set(targetLanguages, forKey: "targetLanguages") } }

    // MARK: - 上下文
    @Published var useAppContext: Bool { didSet { defaults.set(useAppContext, forKey: "useAppContext") } }
    @Published var readNearbyText: Bool { didSet { defaults.set(readNearbyText, forKey: "readNearbyText") } }
    @Published var readSelectedText: Bool { didSet { defaults.set(readSelectedText, forKey: "readSelectedText") } }

    // MARK: - 术语表
    @Published var autoLearn: Bool { didSet { defaults.set(autoLearn, forKey: "autoLearn") } }

    // MARK: - 历史
    @Published var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: "keepHistory") } }
    @Published var transcriptionHistoryRetentionDays: Int {
        didSet {
            defaults.set(transcriptionHistoryRetentionDays,
                         forKey: "transcriptionHistoryRetentionDays")
        }
    }
    @Published var retainedRecordingCount: Int {
        didSet { defaults.set(retainedRecordingCount, forKey: "retainedRecordingCount") }
    }

    // MARK: - 调试
    /// 开启后在历史页显示最近一次请求详情
    @Published var debugMode: Bool { didSet { defaults.set(debugMode, forKey: "debugMode") } }

    // MARK: - 模型来源与模型回退链
    @Published var modelProviders: [ModelProvider] {
        didSet { saveCodable(modelProviders, forKey: "modelProviders") }
    }
    @Published var transcriptionModels: [ConfiguredModel] {
        didSet { saveCodable(transcriptionModels, forKey: "transcriptionModels") }
    }
    @Published var languageModels: [ConfiguredModel] {
        didSet { saveCodable(languageModels, forKey: "languageModels") }
    }

    /// 首启引导是否已完成
    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }

    var defaultTargetLanguage: String { targetLanguages.first ?? "英语" }

    private init() {
        Self.migrateLegacyDefaultsIfNeeded(into: defaults)
        appLanguage = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        editingEffort = EditingEffort(rawValue: defaults.string(forKey: "editingEffort") ?? "") ?? .medium
        formatLevel = FormatLevel(rawValue: defaults.string(forKey: "formatLevel") ?? "") ?? .plain
        playSound = defaults.object(forKey: "playSound") as? Bool ?? true
        showPanel = defaults.object(forKey: "showPanel") as? Bool ?? true
        filterLocalAudio = defaults.object(forKey: "filterLocalAudio") as? Bool ?? false
        let storedTimeout = defaults.integer(forKey: "modelRequestTimeoutSeconds")
        modelRequestTimeoutSeconds = Self.modelRequestTimeoutOptions.contains(storedTimeout)
            ? storedTimeout : Self.defaultModelRequestTimeoutSeconds
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        primaryKey = TriggerKey(rawValue: defaults.string(forKey: "primaryKey") ?? "") ?? .fn
        altKey = TriggerKey(rawValue: defaults.string(forKey: "altKey") ?? "") ?? .none
        recognitionLanguage = defaults.string(forKey: "recognitionLanguage") ?? "auto"
        targetLanguages = defaults.stringArray(forKey: "targetLanguages") ?? ["英语", "中文"]
        useAppContext = defaults.object(forKey: "useAppContext") as? Bool ?? true
        readNearbyText = defaults.object(forKey: "readNearbyText") as? Bool ?? true
        readSelectedText = defaults.object(forKey: "readSelectedText") as? Bool ?? true
        autoLearn = defaults.object(forKey: "autoLearn") as? Bool ?? true
        keepHistory = defaults.object(forKey: "keepHistory") as? Bool ?? true
        let storedHistoryDays = defaults.object(forKey: "transcriptionHistoryRetentionDays") as? Int
        transcriptionHistoryRetentionDays = storedHistoryDays.flatMap {
            Self.transcriptionHistoryRetentionDayOptions.contains($0) ? $0 : nil
        } ?? Self.defaultTranscriptionHistoryRetentionDays
        let storedRecordingCount = defaults.object(forKey: "retainedRecordingCount") as? Int
        retainedRecordingCount = storedRecordingCount.flatMap {
            Self.retainedRecordingCountOptions.contains($0) ? $0 : nil
        } ?? Self.defaultRetainedRecordingCount
        debugMode = defaults.object(forKey: "debugMode") as? Bool ?? false
        let provider = ModelProvider.defaultOpenAI
        let loadedProviders = Self.loadLossyArray(ModelProvider.self, from: defaults,
                                                  key: "modelProviders")
        let safeProviders = Self.normalizedProviders(loadedProviders ?? [provider], fallback: provider)
        modelProviders = safeProviders
        let loadedTranscription = Self.loadLossyArray(ConfiguredModel.self, from: defaults,
                                                       key: "transcriptionModels")
        transcriptionModels = Self.normalizedModels(
            loadedTranscription ?? [], providers: safeProviders, capability: .transcription,
            legacyFallback: provider.kind.defaultPresets(for: .transcription).enumerated().map { index, preset in
                ConfiguredModel(id: "transcription-default-\(index)", providerID: provider.id,
                                modelID: preset.id, displayName: preset.displayName)
            })
        let previousLLM = defaults.string(forKey: "llmModel")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let migratedLLM = (previousLLM?.isEmpty == false ? previousLLM : nil) ?? Self.defaultLLMModel
        let loadedLanguage = Self.loadLossyArray(ConfiguredModel.self, from: defaults,
                                                  key: "languageModels")
        languageModels = Self.normalizedModels(
            loadedLanguage ?? [], providers: safeProviders, capability: .language,
            legacyFallback: [ConfiguredModel(id: "language-primary", providerID: provider.id,
                                             modelID: migratedLLM)])
        onboardingDone = defaults.object(forKey: "onboardingDone") as? Bool ?? false

        // 将逐项容错解码后的结果立即写回当前 schema。以后新增字段、删除来源，
        // 或某条旧记录损坏时，都只会丢弃该条记录而不是让整个模型页无法启动。
        saveCodable(modelProviders, forKey: "modelProviders")
        saveCodable(transcriptionModels, forKey: "transcriptionModels")
        saveCodable(languageModels, forKey: "languageModels")
        defaults.set(Self.modelConfigurationSchemaVersion, forKey: "modelConfigurationSchemaVersion")
    }

    func addProvider(kind: ModelProviderKind, apiKey: String? = nil) -> ModelProvider {
        // 本机来源没有可区分的账号或密钥，不创建重复实例。
        if [.ollama, .appleIntelligence].contains(kind),
           let existing = modelProviders.first(where: { $0.kind == kind }) {
            return existing
        }
        let ordinal = modelProviders.filter { $0.kind == kind }.count + 1
        let provider = ModelProvider(
            id: UUID().uuidString,
            kind: kind,
            name: ordinal == 1 ? kind.displayName : "\(kind.displayName) \(ordinal)"
        )
        modelProviders.append(provider)
        if kind.requiresAPIKey, let apiKey {
            _ = KeychainStore.saveAPIKey(apiKey, providerID: provider.id)
        }
        return provider
    }

    func isProviderConfigured(_ provider: ModelProvider) -> Bool {
        !provider.kind.requiresAPIKey || KeychainStore.loadAPIKey(providerID: provider.id) != nil
    }

    /// 欢迎引导只收集模型来源与必要的密钥；首启时由来源自动提供默认模型链。
    /// 已完成引导的用户重新打开单页配置时，不覆盖他们现有的模型排序。
    func configureOnboardingProvider(kind: ModelProviderKind, apiKey: String? = nil) -> Bool {
        let configuredProviderIDs = Set(modelProviders.compactMap { provider in
            isProviderConfigured(provider) ? provider.id : nil
        })
        let existing = modelProviders.first(where: { $0.kind == kind })
        let provider: ModelProvider
        if let existing {
            provider = existing
        } else {
            provider = ModelProvider(id: UUID().uuidString, kind: kind, name: kind.displayName)
        }
        if kind.requiresAPIKey {
            guard let apiKey, KeychainStore.saveAPIKey(apiKey, providerID: provider.id) else { return false }
        }
        if existing == nil { modelProviders.append(provider) }

        if !onboardingDone {
            // 初始的 OpenAI 来源只是迁移占位；若用户先选其他来源，去掉没有
            // Key 的占位项。之后继续添加另一家时保留第一家的优先顺序。
            modelProviders = modelProviders.filter {
                $0.id == provider.id || isProviderConfigured($0)
            }
            if configuredProviderIDs.isEmpty {
                transcriptionModels = Self.configuredDefaults(
                    kind: kind, capability: .transcription, providerID: provider.id,
                    idPrefix: "onboarding-transcription")
                languageModels = Self.configuredDefaults(
                    kind: kind, capability: .language, providerID: provider.id,
                    idPrefix: "onboarding-language")
            } else {
                appendDefaultModelsIfNeeded(kind: kind, providerID: provider.id)
            }
        } else {
            // 单页引导也可用于给已完成首启的用户补一个新来源。
            appendDefaultModelsIfNeeded(kind: kind, providerID: provider.id)
        }
        return true
    }

    private func appendDefaultModelsIfNeeded(kind: ModelProviderKind, providerID: String) {
        if !transcriptionModels.contains(where: { $0.providerID == providerID }) {
            transcriptionModels.append(contentsOf: Self.configuredDefaults(
                kind: kind, capability: .transcription, providerID: providerID))
        }
        if !languageModels.contains(where: { $0.providerID == providerID }) {
            languageModels.append(contentsOf: Self.configuredDefaults(
                kind: kind, capability: .language, providerID: providerID))
        }
    }

    private static func configuredDefaults(kind: ModelProviderKind, capability: ModelCapability,
                                           providerID: String, idPrefix: String? = nil) -> [ConfiguredModel] {
        kind.defaultPresets(for: capability).enumerated().map { index, preset in
            ConfiguredModel(id: idPrefix.map { "\($0)-\(index)" } ?? UUID().uuidString,
                            providerID: providerID,
                            modelID: preset.id,
                            displayName: preset.displayName)
        }
    }

    /// 删除模型来源时同时删除引用它的模型，避免留下失效引用。
    func removeProvider(_ provider: ModelProvider) {
        guard modelProviders.count > 1 else { return }
        modelProviders.removeAll { $0.id == provider.id }
        transcriptionModels.removeAll { $0.providerID == provider.id }
        languageModels.removeAll { $0.providerID == provider.id }
        KeychainStore.deleteAPIKey(providerID: provider.id)

        let transcriptionReplacement = modelProviders.first {
            !$0.kind.defaultPresets(for: .transcription).isEmpty
        }
        let languageReplacement = modelProviders.first {
            !$0.kind.defaultPresets(for: .language).isEmpty
        }
        if transcriptionModels.isEmpty,
           let replacement = transcriptionReplacement,
           let preset = replacement.kind.defaultPresets(for: .transcription).first {
            transcriptionModels = [ConfiguredModel(providerID: replacement.id, modelID: preset.id,
                                                   displayName: preset.displayName)]
        }
        if languageModels.isEmpty,
           let replacement = languageReplacement,
           let preset = replacement.kind.defaultPresets(for: .language).first {
            languageModels = [ConfiguredModel(providerID: replacement.id, modelID: preset.id,
                                              displayName: preset.displayName)]
        }
    }

    private func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    /// 数组逐项解码，避免一条过时或损坏的模型来源让整个配置数组解码失败。
    private static func loadLossyArray<T: Decodable>(_ type: T.Type, from defaults: UserDefaults,
                                                      key: String) -> [T]? {
        guard let data = defaults.data(forKey: key),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return objects.compactMap { object in
            guard JSONSerialization.isValidJSONObject(object),
                  let itemData = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(type, from: itemData)
        }
    }

    private static func normalizedProviders(_ providers: [ModelProvider],
                                            fallback: ModelProvider) -> [ModelProvider] {
        var seen = Set<String>()
        let result = providers.filter { provider in
            !provider.id.isEmpty && !provider.name.isEmpty && seen.insert(provider.id).inserted
        }
        return result.isEmpty ? [fallback] : result
    }

    private static func normalizedModels(_ models: [ConfiguredModel], providers: [ModelProvider],
                                         capability: ModelCapability,
                                         legacyFallback: [ConfiguredModel]) -> [ConfiguredModel] {
        let providerIDs = Set(providers.map(\.id))
        var seen = Set<String>()
        let result = models.compactMap { item -> ConfiguredModel? in
            guard !item.id.isEmpty, !item.modelID.isEmpty, providerIDs.contains(item.providerID),
                  seen.insert("\(item.providerID)\u{1f}\(item.modelID)").inserted else { return nil }
            var value = item
            if value.displayName.isEmpty { value.displayName = value.modelID }
            return value
        }
        if !result.isEmpty { return result }

        // 旧版默认 OpenAI 占位仍有效时保留；否则根据升级后第一个有效来源重建。
        if legacyFallback.allSatisfy({ providerIDs.contains($0.providerID) }) { return legacyFallback }
        guard let replacement = providers.first else { return [] }
        return replacement.kind.defaultPresets(for: capability).enumerated().map { index, preset in
            ConfiguredModel(id: "recovered-\(capability.rawValue)-\(index)",
                            providerID: replacement.id, modelID: preset.id,
                            displayName: preset.displayName)
        }
    }

    // MARK: - 悬浮条位置(按屏幕记忆)
    func savedPanelOrigin() -> CGPoint? {
        guard let dict = defaults.dictionary(forKey: "panelOrigin"),
              let x = dict["x"] as? Double, let y = dict["y"] as? Double else { return nil }
        return CGPoint(x: x, y: y)
    }

    func savePanelOrigin(_ p: CGPoint) {
        defaults.set(["x": p.x, "y": p.y], forKey: "panelOrigin")
    }

    func clearPanelOrigin() {
        defaults.removeObject(forKey: "panelOrigin")
    }

    // MARK: - 更新提示

    /// 用户关闭过的升级气泡版本；设置页里的手动更新按钮不受影响。
    var dismissedUpdateVersion: String? {
        defaults.string(forKey: "dismissedUpdateVersion")
    }

    func dismissUpdate(version: String) {
        defaults.set(version, forKey: "dismissedUpdateVersion")
    }

    /// 应用由 com.openvoiceinput.app 改名 com.openvoice.app 后,
    /// UserDefaults 域随 Bundle ID 变化,首次启动把旧设置整体搬过来
    private static func migrateLegacyDefaultsIfNeeded(into defaults: UserDefaults) {
        guard defaults.object(forKey: "onboardingDone") == nil else { return }
        let legacyPlist = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/com.openvoiceinput.app.plist")
        guard let dict = NSDictionary(contentsOf: legacyPlist) as? [String: Any] else { return }
        for (key, value) in dict {
            defaults.set(value, forKey: key)
        }
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("SMAppService failed: \(error.localizedDescription)")
        }
    }
}
