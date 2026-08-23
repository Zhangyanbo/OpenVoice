import AppKit

/// 菜单栏应用(LSUIElement,无 Dock 图标)。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let controller = DictationController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
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

    // MARK: - 主菜单

    /// LSUIElement 应用没有可见菜单栏,但必须装一个主菜单,
    /// 否则 ⌘V/⌘C/⌘A 等编辑快捷键在设置/引导窗口的输入框里全部失效
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出 OpenVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // 用户提供的纯白透明底图标作为 template image:
            // 系统按 alpha 通道着色,自动适配菜单栏深浅色与选中态
            if let path = Bundle.main.path(forResource: "icon_design_bar", ofType: "png"),
               let image = NSImage(contentsOfFile: path) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "OpenVoice")
            }
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "开始语音输入", action: #selector(startDictation), keyEquivalent: "").target = self
        menu.addItem(withTitle: "开始翻译输入", action: #selector(startTranslation), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "转录历史…", action: #selector(openHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重新打开欢迎引导", action: #selector(openOnboarding), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 OpenVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    @objc private func openHistory() {
        SettingsWindowController.shared.show(tab: .history)
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
            guard let self else { return }
            switch trigger {
            case .toggleDictation: self.controller.toggleDictation()
            case .toggleTranslation: self.controller.toggleTranslation()
            case .cancel: self.controller.cancel()
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
