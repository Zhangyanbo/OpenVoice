import Foundation
import Combine
import ServiceManagement

/// 所有用户设置的唯一入口,UserDefaults 持久化。
/// 模型名等默认值只在这里定义,其他代码不得硬编码。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    static let defaultTranscribeModel = "gpt-4o-transcribe"
    static let defaultLLMModel = "gpt-5.6-luna"

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
            case .none: return "无"
            case .fn: return "Fn (🌐)"
            case .rightCommand: return "右 Command"
            case .rightOption: return "右 Option"
            case .f13: return "F13"
            case .f14: return "F14"
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

    private let defaults = UserDefaults.standard

    // MARK: - 通用
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published var showPanel: Bool { didSet { defaults.set(showPanel, forKey: "showPanel") } }
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
        playSound = defaults.object(forKey: "playSound") as? Bool ?? true
        showPanel = defaults.object(forKey: "showPanel") as? Bool ?? true
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
