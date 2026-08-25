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

    // MARK: - 调试
    /// 开启后在历史页显示最近一次请求详情
    @Published var debugMode: Bool { didSet { defaults.set(debugMode, forKey: "debugMode") } }

    // MARK: - OpenAI
    /// 空字符串表示"默认"
    @Published var transcribeModel: String { didSet { defaults.set(transcribeModel, forKey: "transcribeModel") } }
    @Published var llmModel: String { didSet { defaults.set(llmModel, forKey: "llmModel") } }

    /// 首启引导是否已完成
    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }

    var effectiveTranscribeModel: String {
        transcribeModel.isEmpty ? Self.defaultTranscribeModel : transcribeModel
    }
    var effectiveLLMModel: String {
        llmModel.isEmpty ? Self.defaultLLMModel : llmModel
    }
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
        debugMode = defaults.object(forKey: "debugMode") as? Bool ?? false
        transcribeModel = defaults.string(forKey: "transcribeModel") ?? ""
        llmModel = defaults.string(forKey: "llmModel") ?? ""
        onboardingDone = defaults.object(forKey: "onboardingDone") as? Bool ?? false
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
