import AppKit
import Combine

/// 菜单栏应用；设置窗口打开时临时显示 Dock 图标。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let controller = DictationController()
    private var tapWatchdog: Timer?
    private var startItem: NSMenuItem!
    private var translateItem: NSMenuItem!
    private var cancellables = Set<AnyCancellable>()
    private var pendingUpdateVersion: String?
    private var updatePromptTimer: Timer?
    private var modelCatalogTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsStore.shared.applyAppearance()
        SoundPlayer.prepare()
        setupStatusItem()
        setupHotkeys()
        setupAutoLearnToast()
        setupUpdates()
        setupModelCatalogRefresh()
        startTapWatchdog()

        // 切换界面语言时重建所有原生菜单(SwiftUI 界面靠视图观察自动刷新,
        // AppKit 菜单没有响应式机制,必须手动重建)
        SettingsStore.shared.$appLanguage
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setupMainMenu()
                self?.setupStatusItemMenu()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: .openSettingsRequest, object: nil, queue: .main) { _ in
            SettingsWindowController.shared.show()
        }

        // 历史栏「重新转录」:用保留的录音原地重跑转录流程
        NotificationCenter.default.addObserver(forName: .retranscribeRequest, object: nil, queue: .main) { [weak self] note in
            guard let request = note.object as? RetranscribeRequest else { return }
            self?.controller.retranscribe(request)
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

    /// 与 OpenCode CLI 一致，启动时检查动态模型目录，并在 App 常驻期间
    /// 每小时刷新。目录管理器自身有 5 分钟 TTL，重复打开设置不会刷爆接口。
    private func setupModelCatalogRefresh() {
        Task { @MainActor in
            OpenCodeModelCatalog.shared.refreshConfiguredProviders()
        }
        modelCatalogTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in
                OpenCodeModelCatalog.shared.refreshConfiguredProviders(force: true)
            }
        }
    }

    /// 用户点击 Dock 图标（包括设置窗口已最小化时），始终显示设置界面。
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    // MARK: - 主菜单

    /// LSUIElement 应用没有可见菜单栏,但必须装一个主菜单,
    /// 否则 ⌘V/⌘C/⌘A 等编辑快捷键在设置/引导窗口的输入框里全部失效
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: tr("退出 OpenVoice"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: tr("编辑"))
        editMenu.addItem(withTitle: tr("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: tr("重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: tr("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: tr("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: tr("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: tr("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
        setupMainMenu()
        setupStatusItemMenu()
    }

    /// 重建状态栏菜单(语言切换时整体重建,保证文案即时更新)
    private func setupStatusItemMenu() {
        let menu = NSMenu()
        menu.delegate = self
        startItem = menu.addItem(withTitle: tr("开始语音输入"), action: #selector(startDictation), keyEquivalent: "")
        startItem.target = self
        translateItem = menu.addItem(withTitle: tr("开始翻译输入"), action: #selector(startTranslation), keyEquivalent: "")
        translateItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("设置…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: tr("转录历史…"), action: #selector(openHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("重新打开欢迎引导"), action: #selector(openOnboarding), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("退出 OpenVoice"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    /// 录音中把「开始」项换成「停止」,保证没有快捷键(如权限异常时)也能停下来
    func menuNeedsUpdate(_ menu: NSMenu) {
        let recording = controller.isRecording
        startItem.title = recording ? tr("停止录音并转录") : tr("开始语音输入")
        translateItem.isHidden = recording
    }

    @objc private func startDictation() {
        // 停止不需要焦点,立即执行
        if controller.isRecording {
            controller.toggleDictation()
            return
        }
        // 从菜单触发开始时,焦点会短暂在菜单上;稍等让焦点回到目标 App
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.controller.toggleDictation()
        }
    }

    @objc private func startTranslation() {
        guard !controller.isRecording else { return }
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

    /// 事件 tap 看门狗:没有辅助功能权限时 tap 创建会静默失败,
    /// 用户事后在系统设置里授权也不会有任何回调 —— 必须轮询重建,
    /// 否则 Fn 在重启 app 之前一直失灵(改名丢权限后踩过的坑)
    private func startTapWatchdog() {
        tapWatchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.hotkeys.isActive && Permissions.accessibilityGranted {
                self.hotkeys.restart()
            }
        }
    }

    // MARK: - 自动学习提示(spec §12)

    private func setupAutoLearnToast() {
        controller.autoLearner.onLearned = { term, undo in
            ToastPanel.show(message: tr("已学习“%@”", term), actionTitle: tr("撤销"), action: undo)
        }
    }

    // MARK: - 自动更新

    private func setupUpdates() {
        let updater = UpdateManager.shared
        let panel = FloatingPanelController.shared
        updater.onUpdateAvailable = { [weak self] version in
            self?.enqueueUpdatePrompt(version: version)
        }
        panel.onInstallUpdate = {
            self.pendingUpdateVersion = nil
            self.updatePromptTimer?.invalidate()
            updater.installAvailableUpdate()
        }
        panel.onDismissUpdate = { [weak self, weak panel] in
            self?.pendingUpdateVersion = nil
            self?.updatePromptTimer?.invalidate()
            updater.dismissUpdateBubble()
            panel?.hide()
        }
        updater.startAutomaticChecks()
    }

    private func enqueueUpdatePrompt(version: String) {
        pendingUpdateVersion = version
        if presentPendingUpdateIfPossible() { return }
        updatePromptTimer?.invalidate()
        updatePromptTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.presentPendingUpdateIfPossible() { timer.invalidate() }
        }
    }

    @discardableResult
    private func presentPendingUpdateIfPossible() -> Bool {
        guard let version = pendingUpdateVersion,
              controller.canPresentUpdatePrompt else { return false }
        pendingUpdateVersion = nil
        FloatingPanelController.shared.showUpdate(version: version)
        return true
    }
}
