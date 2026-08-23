import AppKit
import SwiftUI

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

    func show() {
        if window == nil {
            let view = OnboardingView(
                onAccessibilityGranted: { [weak self] in self?.onAccessibilityGranted?() },
                onFinish: { [weak self] in
                    SettingsStore.shared.onboardingDone = true
                    self?.window?.close()
                }
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "欢迎使用 OpenVoiceInput"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 480, height: 420))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct OnboardingView: View {
    let onAccessibilityGranted: () -> Void
    let onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, apiKey, microphone, accessibility, tryIt
    }

    @State private var step: Step = .welcome
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
                Text("OpenVoiceInput").font(.system(size: 24, weight: .bold))
                Text("把光标放到任意地方,按 Fn 说话,再按 Fn,\n文字直接出现。")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                Text("无账号、无服务器。你的 OpenAI API Key 保存在本机 Keychain,\n音频直接从这台 Mac 发送给 OpenAI。")
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

        case .apiKey:
            VStack(alignment: .leading, spacing: 12) {
                Text("填写 OpenAI API Key").font(.title2.bold())
                Text("在 platform.openai.com 创建。Key 只保存在 macOS Keychain 中,不写入配置文件,不进入日志。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                SecureField("sk-…", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(validating ? "验证中…" : "验证并保存") { validate() }
                        .disabled(keyInput.isEmpty || validating)
                    if !keyStatus.isEmpty {
                        Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

        case .microphone:
            permissionStep(title: "授予麦克风权限",
                           description: "只在语音输入期间使用,录音结束立即停止访问。",
                           granted: micGranted,
                           buttonTitle: "允许使用麦克风") {
                Permissions.requestMicrophone { granted in
                    micGranted = granted
                    if !granted { Permissions.openMicrophoneSettings() }
                }
            }

        case .accessibility:
            permissionStep(title: "授予辅助功能权限",
                           description: "用于全局快捷键、读取光标附近文字、把结果写回光标位置。不截图、不录屏。",
                           granted: axGranted,
                           buttonTitle: "打开系统设置") {
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }

        case .tryIt:
            VStack(alignment: .leading, spacing: 12) {
                Text("试一下").font(.title2.bold())
                Text("点击下面的输入框,按 \(SettingsStore.shared.primaryKey.displayName),说一句话,再按一次。")
                    .foregroundStyle(.secondary)
                TextEditor(text: $tryText)
                    .font(.body)
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Text("提示:若使用 Fn,请先在 系统设置 → 键盘 中把「按下 🌐 键时」设为「无操作」。")
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
                Text(granted ? "已授权" : "未授权")
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
            if step != .welcome {
                Button("上一步") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
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
                Button("完成") { onFinish() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("继续") { step = Step(rawValue: step.rawValue + 1) ?? .tryIt }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: step)
    }

    private var canContinue: Bool {
        switch step {
        case .welcome: return true
        case .apiKey: return KeychainStore.loadAPIKey() != nil
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
                    keyStatus = "✓ 已保存"
                }
            } catch {
                await MainActor.run {
                    validating = false
                    keyStatus = "OpenAI 无法验证这个 API Key。"
                }
            }
        }
    }
}
