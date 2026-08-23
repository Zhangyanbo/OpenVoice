import AppKit

/// 菜单栏应用(LSUIElement,无 Dock 图标)。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let controller = DictationController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHotkeys()
        setupAutoLearnToast()

        NotificationCenter.default.addObserver(forName: .openSettingsRequest, object: nil, queue: .main) { _ in
            SettingsWindowController.shared.show()
        }

        OnboardingWindowController.shared.onAccessibilityGranted = { [weak self] in
            self?.hotkeys.restart()
        }
        OnboardingWindowController.shared.showIfNeeded()

        // 已完成引导但权限尚未授予时,把 App 加入辅助功能列表提示用户
        if SettingsStore.shared.onboardingDone && !Permissions.accessibilityGranted {
            Permissions.promptAccessibility()
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "OpenVoiceInput")
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "开始语音输入", action: #selector(startDictation), keyEquivalent: "").target = self
        menu.addItem(withTitle: "开始翻译输入", action: #selector(startTranslation), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "查看上次发送的上下文", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重新打开欢迎引导", action: #selector(openOnboarding), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 OpenVoiceInput", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func startDictation() {
        // 从菜单触发时,焦点会短暂在菜单上;稍等让焦点回到目标 App
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.controller.toggleDictation()
        }
    }

    @objc private func startTranslation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.controller.toggleTranslation()
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openOnboarding() {
        OnboardingWindowController.shared.show()
    }

    // MARK: - 快捷键

    private func setupHotkeys() {
        hotkeys.isRecordingProvider = { [weak self] in
            self?.controller.isRecording ?? false
        }
        hotkeys.onTrigger = { [weak self] trigger in
            guard let self else { return false }
            switch trigger {
            case .toggleDictation:
                self.controller.toggleDictation()
                return true
            case .toggleTranslation:
                self.controller.toggleTranslation()
                return true
            case .cancel:
                self.controller.cancel()
                return true
            }
        }
        hotkeys.start()
    }

    // MARK: - 自动学习提示(spec §12)

    private func setupAutoLearnToast() {
        controller.autoLearner.onLearned = { term, undo in
            ToastPanel.show(message: "已学习“\(term)”", actionTitle: "撤销", action: undo)
        }
    }
}
