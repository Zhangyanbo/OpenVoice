import AppKit
import SwiftUI

/// 引导步骤。除了首启完整流程,单个步骤也可作为"权限/配置缺失"时的
/// 引导页独立弹出(用户在使用中缺什么就看到什么,而不是干巴巴的警告框)
enum OnboardingStep: Int, CaseIterable {
    case welcome, apiKey, microphone, accessibility, tryIt
}

/// 首次启动引导(spec §16):欢迎 → API Key → 麦克风 → 辅助功能 → 试一下。
/// 无账号、无注册,完成后不再出现。
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    /// 辅助功能授权后需要重建事件 tap
    var onAccessibilityGranted: (() -> Void)?

    func showIfNeeded() {
        guard !SettingsStore.shared.onboardingDone else { return }
        show()
    }

    /// step 为 nil 走完整引导;指定 step 则以单页模式只展示该步骤
    func show(step: OnboardingStep? = nil) {
        let standalone = step != nil
        let view = OnboardingView(
            initialStep: step ?? .welcome,
            standalone: standalone,
            onAccessibilityGranted: { [weak self] in self?.onAccessibilityGranted?() },
            onFinish: { [weak self] in
                if !standalone { SettingsStore.shared.onboardingDone = true }
                self?.window?.close()
            }
        )
        let hosting = NSHostingController(rootView: view)
        if window == nil {
            let window = NSWindow(contentViewController: hosting)
            window.title = tr("欢迎使用 OpenVoice")
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 480, height: 420))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        } else {
            window?.contentViewController = hosting
            window?.setContentSize(NSSize(width: 480, height: 420))
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct OnboardingView: View {
    @ObservedObject var settings = SettingsStore.shared
    let initialStep: OnboardingStep
    /// 单页模式:只展示一个步骤,满足条件后「完成」直接关窗
    let standalone: Bool
    let onAccessibilityGranted: () -> Void
    let onFinish: () -> Void

    typealias Step = OnboardingStep

    @State private var step: Step
    /// 钥匙串中已有可用的 Key(读取动作本身会在需要时触发系统确认框)
    @State private var keySaved = false
    @State private var replacingKey = false

    init(initialStep: OnboardingStep, standalone: Bool,
         onAccessibilityGranted: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.initialStep = initialStep
        self.standalone = standalone
        self.onAccessibilityGranted = onAccessibilityGranted
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }
    @State private var keyInput = ""
    @State private var keyStatus = ""
    @State private var validating = false
    @State private var micGranted = Permissions.microphoneGranted
    @State private var axGranted = Permissions.accessibilityGranted
    @State private var tryText = ""

    /// 轮询权限状态(系统设置里授权后没有回调)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: 480, height: 400)
        .onReceive(timer) { _ in
            micGranted = Permissions.microphoneGranted
            let ax = Permissions.accessibilityGranted
            if ax && !axGranted { onAccessibilityGranted() }
            axGranted = ax
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            VStack(spacing: 16) {
                AppMark(size: 72)
                    .padding(.top, 12)
                Text("OpenVoice").font(.system(size: 24, weight: .bold))
                Text(tr("把光标放到任意地方，按 Fn 说话，再按 Fn，\n文字直接出现。"))
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                Text(tr("无账号、无服务器。你的 OpenAI API Key 保存在本机钥匙串，\n音频直接从这台 Mac 发送给 OpenAI。"))
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

        case .apiKey:
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("设置 OpenAI API Key")).font(.title2.bold())
                Text(tr("在 platform.openai.com 创建。Key 只保存在 macOS 钥匙串中，不写入配置文件，不进入日志。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if keySaved && !replacingKey {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(tr("已从钥匙串读取到保存的 API Key"))
                        Spacer()
                        Button(tr("更换…")) { replacingKey = true }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    SecureField("sk-…", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button(validating ? tr("正在验证…") : tr("验证并保存")) { validate() }
                            .disabled(keyInput.isEmpty || validating)
                        if !keyStatus.isEmpty {
                            Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(tr("如果系统弹出「访问钥匙串」的确认框，请选择「始终允许」，之后不会再询问。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 主动读取一次钥匙串:若需要系统确认,就让确认框弹在
            // 这个有上下文说明的页面里,而不是使用中突然出现
            .onAppear { keySaved = KeychainStore.loadAPIKey() != nil }

        case .microphone:
            permissionStep(title: tr("授予麦克风权限"),
                           description: tr("只在语音输入期间使用，录音结束立即停止访问。"),
                           granted: micGranted,
                           buttonTitle: tr("允许使用麦克风")) {
                Permissions.requestMicrophone { granted in
                    micGranted = granted
                    if !granted { Permissions.openMicrophoneSettings() }
                }
            }

        case .accessibility:
            permissionStep(title: tr("授予辅助功能权限"),
                           description: tr("用于全局快捷键、读取光标附近文字、把结果写回光标位置。不截图、不录屏。"),
                           granted: axGranted,
                           buttonTitle: tr("打开系统设置")) {
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }

        case .tryIt:
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("试一下")).font(.title2.bold())
                Text(tr("点击下面的输入框，按 %@，说一句话，再按一次。", SettingsStore.shared.primaryKey.displayName))
                    .foregroundStyle(.secondary)
                TextEditor(text: $tryText)
                    .font(.body)
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Text(tr("提示：若使用 Fn，请先在 系统设置 → 键盘 中把「按下 🌐 键时」设为「无操作」。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func permissionStep(title: String, description: String, granted: Bool,
                                buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            Text(description).font(.callout).foregroundStyle(.secondary)
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? .green : .secondary)
                Text(granted ? tr("已授权") : tr("未授权"))
                Spacer()
                if !granted {
                    Button(buttonTitle, action: action)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var footer: some View {
        HStack {
            if standalone {
                // 单页模式:满足条件即可完成,不引导后续步骤
                Spacer()
                Button(tr("完成")) { onFinish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
            } else {
                if step != .welcome {
                    Button(tr("上一步")) { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                }
                Spacer()
                // 步骤指示点
                HStack(spacing: 5) {
                    ForEach(Step.allCases, id: \.rawValue) { s in
                        Circle()
                            .fill(s == step ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if step == .tryIt {
                    Button(tr("完成")) { onFinish() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(tr("继续")) { step = Step(rawValue: step.rawValue + 1) ?? .tryIt }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canContinue)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: step)
    }

    private var canContinue: Bool {
        switch step {
        case .welcome: return true
        case .apiKey: return keySaved
        case .microphone: return micGranted
        case .accessibility: return axGranted
        case .tryIt: return true
        }
    }

    private func validate() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        validating = true
        keyStatus = ""
        Task {
            do {
                try await OpenAIClient(apiKey: key).validateKey()
                _ = KeychainStore.saveAPIKey(key)
                await MainActor.run {
                    validating = false
                    keyStatus = tr("✓ 已保存")
                    keySaved = true
                    replacingKey = false
                    keyInput = ""
                }
            } catch {
                await MainActor.run {
                    validating = false
                    keyStatus = tr("OpenAI 无法验证这个 API Key。")
                }
            }
        }
    }
}
