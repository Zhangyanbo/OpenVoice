import AppKit
import SwiftUI

/// 引导步骤。除了首启完整流程,单个步骤也可作为"权限/配置缺失"时的
/// 引导页独立弹出(用户在使用中缺什么就看到什么,而不是干巴巴的警告框)
enum OnboardingStep: Int, CaseIterable {
    case welcome, provider, microphone, accessibility, tryIt
}

/// 首次启动引导(spec §16):欢迎 → 模型来源 → 麦克风 → 辅助功能 → 试一下。
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
    @State private var configuredProviderKinds = Set<ModelProviderKind>()
    @State private var editingProviderKind: ModelProviderKind?

    init(initialStep: OnboardingStep, standalone: Bool,
         onAccessibilityGranted: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.initialStep = initialStep
        self.standalone = standalone
        self.onAccessibilityGranted = onAccessibilityGranted
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }
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
        .sheet(item: $editingProviderKind) { kind in
            OnboardingProviderKeySheet(kind: kind) {
                refreshConfiguredProviders()
            }
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
                Text(tr("无账号、无中间服务器。云端 API Key 只保存在本机钥匙串；\n选择本地模型时，音频不会离开这台 Mac。"))
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

        case .provider:
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("添加模型来源")).font(.title2.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    ForEach(ModelProviderKind.allCases.filter { $0 != .appleIntelligence }) { kind in
                        let configured = configuredProviderKinds.contains(kind)
                        Button {
                            if !configured { editingProviderKind = kind }
                        } label: {
                            HStack(spacing: 10) {
                                ProviderIcon(kind: kind, size: 30)
                                Text(configured ? kind.displayName : tr("添加 %@", kind.displayName))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Image(systemName: configured ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(configured ? Color.green : Color.accentColor)
                            }
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(configured ? Color.green.opacity(0.30) : Color.primary.opacity(0.08),
                                              lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        // 已添加的卡片不响应点击，但不用 disabled，
                        // 避免系统把绿色完成状态整体变灰。
                        .allowsHitTesting(!configured)
                    }
                }
            }
            .onAppear { refreshConfiguredProviders() }

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
        case .provider: return !configuredProviderKinds.isEmpty
        case .microphone: return micGranted
        case .accessibility: return axGranted
        case .tryIt: return true
        }
    }

    private func refreshConfiguredProviders() {
        configuredProviderKinds = Set(settings.modelProviders.compactMap { provider in
            settings.isProviderConfigured(provider) ? provider.kind : nil
        })
    }
}

private struct OnboardingProviderKeySheet: View {
    let kind: ModelProviderKind
    let onAdded: () -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var ollama = OllamaModelManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var keyInput = ""
    @State private var status = ""
    @State private var validating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProviderIcon(kind: kind, size: 30)
                Text(tr("添加 %@", kind.displayName))
                    .font(.system(size: 18, weight: .semibold))
            }
            Text(kind.introduction)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if kind.requiresAPIKey {
                SecureField(tr("API Key"), text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                VStack(alignment: .leading, spacing: 4) {
                    if let help = kind.apiKeyHelp {
                        Text(help).foregroundStyle(.secondary)
                    }
                    if let url = kind.apiKeyURL {
                        Link(tr("获取 API Key"), destination: url)
                    }
                }
                .font(.system(size: 11))
            } else if kind == .ollama {
                OllamaInstallationView()
            }
            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(tr("取消")) { dismiss() }
                Button(validating ? tr("正在验证…")
                                  : (kind.requiresAPIKey ? tr("验证并添加") : tr("添加")),
                       action: validate)
                    .buttonStyle(.borderedProminent)
                    .disabled((kind.requiresAPIKey
                               && keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                              || (kind == .ollama && !ollama.ollamaInstalled)
                              || validating)
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private func validate() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind.requiresAPIKey else {
            guard settings.configureOnboardingProvider(kind: kind) else { return }
            onAdded()
            dismiss()
            return
        }
        validating = true
        status = ""
        Task {
            do {
                switch kind {
                case .openAI: try await OpenAIClient(apiKey: key).validateKey()
                case .google: try await GeminiClient(apiKey: key).validateKey()
                case .ollama, .appleIntelligence: break
                case .openCodeZen, .openCodeGo:
                    try await OpenCodeClient(providerID: "onboarding-validation",
                                             kind: kind, apiKey: key).validateKey()
                }
                await MainActor.run {
                    guard settings.configureOnboardingProvider(kind: kind, apiKey: key) else {
                        validating = false
                        status = tr("无法保存 API Key，请重试。")
                        return
                    }
                    validating = false
                    OpenCodeModelCatalog.shared.refreshConfiguredProviders(force: true)
                    onAdded()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    validating = false
                    status = tr("%@ 无法验证这个 API Key。", kind.displayName)
                }
            }
        }
    }
}
