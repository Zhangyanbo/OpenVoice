import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口:左侧图标侧边栏 + 右侧卡片式分区。
/// 视觉语言与悬浮条一致:克制、现代、低噪。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private let nav = SettingsNav()

    enum Tab: String, CaseIterable {
        case general, models, personalization, privacy, glossary, history, request, about

        var title: String {
            switch self {
            case .general: return tr("通用")
            case .models: return tr("模型")
            case .personalization: return tr("个性化")
            case .privacy: return tr("隐私")
            case .glossary: return tr("术语表")
            case .history: return tr("历史")
            case .request: return tr("请求")
            case .about: return tr("关于")
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .models: return "square.stack.3d.up.fill"
            case .personalization: return "slider.horizontal.3"
            case .privacy: return "hand.raised.fill"
            case .glossary: return "character.book.closed.fill"
            case .history: return "clock.arrow.circlepath"
            case .request: return "arrow.up.forward.app.fill"
            case .about: return "info.circle.fill"
            }
        }

        var iconColor: Color {
            switch self {
            case .general: return Color(red: 0.42, green: 0.48, blue: 0.56)
            case .models: return Color(red: 0.33, green: 0.47, blue: 0.92)
            case .personalization: return Color(red: 0.20, green: 0.72, blue: 0.55)
            case .privacy: return Color(red: 0.25, green: 0.55, blue: 0.9)
            case .glossary: return Color(red: 0.95, green: 0.61, blue: 0.19)
            case .history: return Color(red: 0.56, green: 0.45, blue: 0.86)
            case .request: return Color(red: 0.85, green: 0.35, blue: 0.30)
            case .about: return Color(red: 0.52, green: 0.56, blue: 0.62)
            }
        }
    }

    func show(tab: Tab? = nil) {
        // 平时是菜单栏 App；设置窗口出现期间切为普通 App，让 Dock 显示图标。
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let content = SettingsRootView(nav: nav)
            let hosting = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: hosting)
            window.title = tr("OpenVoice 设置")
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 720, height: 520))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        if let tab { nav.tab = tab }
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 只收起设置窗口与 Dock 图标；应用和菜单栏状态项继续运行。
        NSApp.setActivationPolicy(.accessory)
    }
}

final class SettingsNav: ObservableObject {
    @Published var tab: SettingsWindowController.Tab = .general
}

// MARK: - 根布局:侧边栏 + 内容

struct SettingsRootView: View {
    @ObservedObject var nav: SettingsNav
    // 观察设置:切换界面语言时整个窗口(含侧边栏)立即刷新
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        // 「请求」是调试功能,Debug 关闭时从侧边栏隐藏;若当前正停在请求页则退回通用页
        let tabs = SettingsWindowController.Tab.allCases.filter { $0 != .request || settings.debugMode }
        HStack(spacing: 0) {
            sidebar(tabs)
            Divider()
            Group {
                switch nav.tab {
                case .general: GeneralPane()
                case .models: ModelsPane()
                case .personalization: PersonalizationPane()
                case .privacy: PrivacyPane()
                case .glossary: GlossaryPane()
                case .history: HistoryPane()
                case .request: RequestPane()
                case .about: AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 720, height: 520)
        .onChange(of: settings.debugMode) { _, debug in
            if !debug && nav.tab == .request { nav.tab = .general }
        }
    }

    private func sidebar(_ tabs: [SettingsWindowController.Tab]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // 给交通灯留位
            Spacer().frame(height: 40)

            // 头部:大图标居中竖排,不拘泥于「左图右字」
            VStack(spacing: 1) {
                AppMark(size: 64)
                Text("OpenVoice")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.82))
                Text(tr("版本 %@", appVersion))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)

            ForEach(tabs, id: \.self) { tab in
                SidebarItem(tab: tab, selected: nav.tab == tab) {
                    nav.tab = tab
                }
            }
            Spacer()
            UpdateSidebarButton()
        }
        .padding(10)
        .frame(width: 178)
        .background(.regularMaterial)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

private struct UpdateSidebarButton: View {
    @ObservedObject var updater = UpdateManager.shared
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isAvailable ? Color.blue.gradient : Color.secondary.opacity(0.14).gradient)
                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(isAvailable ? .white : .secondary)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(isAvailable ? .white : .secondary)
                    }
                }
                .frame(width: 22, height: 22)
                Text(title)
                    .font(.system(size: 11.5, weight: isAvailable ? .semibold : .regular))
                    .foregroundStyle(isAvailable ? Color.blue : Color.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help(helpText)
        .onHover { hovering = $0 }
    }

    private var isAvailable: Bool {
        updater.availableRelease != nil
    }

    private var isBusy: Bool {
        switch updater.phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var icon: String {
        switch updater.phase {
        case .upToDate: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .available: return "arrow.down.circle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var title: String {
        switch updater.phase {
        case .checking: return tr("正在检查…")
        case .upToDate: return tr("已是最新版本")
        case .available:
            return tr("更新到 %@", updater.availableRelease?.version ?? "")
        case .downloading: return tr("正在下载…")
        case .installing: return tr("正在安装…")
        case .failed: return tr("更新失败，重试")
        case .idle: return tr("检查更新…")
        }
    }

    private var helpText: String {
        if case .failed(let message) = updater.phase { return message }
        return title
    }

    private func action() {
        if updater.availableRelease != nil {
            updater.installAvailableUpdate()
        } else {
            updater.checkForUpdates(manual: true)
        }
    }
}

private struct SidebarItem: View {
    let tab: SettingsWindowController.Tab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(tab.iconColor.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(tab.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.09)
                          : hovering ? Color.primary.opacity(0.04) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 通用组件:卡片与行

/// 分区卡片:标题 + 圆角容器,行之间自动加内嵌分隔线
struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 卡片内的一行:左侧标题(可带副标题),右侧控件
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct CardDivider: View {
    var body: some View {
        Divider().padding(.leading, 12).opacity(0.6)
    }
}

/// 统一的内容滚动容器
private struct PaneScroll<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .padding(.top, 34)
                content
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 通用

private struct GeneralPane: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        PaneScroll(title: tr("通用")) {
            SettingsCard {
                SettingsRow(title: tr("登录时启动")) {
                    Toggle("", isOn: $settings.launchAtLogin)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                CardDivider()
                SettingsRow(title: tr("播放提示音"), subtitle: tr("录音开始与结束时")) {
                    Toggle("", isOn: $settings.playSound)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                CardDivider()
                SettingsRow(title: tr("过滤本机声音"), subtitle: tr("开启后过滤电脑播放的声音，适合会议中同时使用")) {
                    Toggle("", isOn: $settings.filterLocalAudio)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                CardDivider()
                SettingsRow(title: tr("显示语音悬浮条"), subtitle: tr("悬浮条可拖动，位置会被记住")) {
                    HStack(spacing: 10) {
                        Button(tr("重置位置")) { settings.clearPanelOrigin() }
                            .controlSize(.small)
                        Toggle("", isOn: $settings.showPanel)
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                }
                CardDivider()
                SettingsRow(title: tr("外观")) {
                    Picker("", selection: $settings.appearanceMode) {
                        ForEach(SettingsStore.AppearanceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden().fixedSize().id(L10n.effective)
                }
                CardDivider()
                SettingsRow(title: "Debug", subtitle: tr("在历史页显示最近一次请求详情")) {
                    Toggle("", isOn: $settings.debugMode)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
            }

            SettingsCard(title: tr("快捷键"),
                         footer: tr("若使用 Fn，请在 系统设置 → 键盘 中把「按下 🌐 键时」设为「无操作」，避免与系统听写冲突。")) {
                SettingsRow(title: tr("语音输入")) {
                    Picker("", selection: $settings.primaryKey) {
                        ForEach(SettingsStore.TriggerKey.allCases.filter { $0 != .none }) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden().fixedSize().id(L10n.effective)
                }
                CardDivider()
                SettingsRow(title: tr("备用快捷键")) {
                    Picker("", selection: $settings.altKey) {
                        ForEach(SettingsStore.TriggerKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden().fixedSize().id(L10n.effective)
                }
                CardDivider()
                SettingsRow(title: tr("翻译")) {
                    Text(tr("%@ + 左 Shift", settings.primaryKey.displayName))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            LanguageCard()

        }
    }
}

// MARK: - 个性化

private struct PersonalizationPane: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        PaneScroll(title: tr("个性化")) {
            SettingsCard(title: tr("编辑力度"),
                         footer: tr("控制整理模型对转录文本的改写程度。最低只删除填充词、重复的句子和无意义的口头语，补全标点；中等在此基础上理顺句子，但不增删内容；最高则把转录当作草稿，按原意完全重写。")) {
                SettingsRow(title: tr("编辑力度")) {
                    LevelSlider(low: tr("低"), high: tr("高"),
                                index: Binding(
                                    get: { Double(SettingsStore.EditingEffort.allCases.firstIndex(of: settings.editingEffort) ?? 1) },
                                    set: { settings.editingEffort = SettingsStore.EditingEffort.allCases[Int($0)] }))
                }
            }

            SettingsCard(title: tr("格式化程度"),
                         footer: tr("控制输出文本的组织形式。最低保持说话时的自然分段，不添加任何结构；中等在内容适合列举时使用简单的项目符号或编号；最高则用小节标题、项目符号等完整层级来组织内容。")) {
                SettingsRow(title: tr("格式化程度")) {
                    LevelSlider(low: tr("低"), high: tr("高"),
                                index: Binding(
                                    get: { Double(SettingsStore.FormatLevel.allCases.firstIndex(of: settings.formatLevel) ?? 0) },
                                    set: { settings.formatLevel = SettingsStore.FormatLevel.allCases[Int($0)] }))
                }
            }
        }
    }
}

/// 三档横向滑杆，样式类似系统设置里的鼠标跟踪速度
private struct LevelSlider: View {
    let low: String
    let high: String
    let index: Binding<Double>

    var body: some View {
        HStack(spacing: 8) {
            Text(low)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Slider(value: index, in: 0...2, step: 1)
                .frame(width: 150)
            Text(high)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 隐私

private struct PrivacyPane: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        PaneScroll(title: tr("隐私")) {
            SettingsCard(title: tr("上下文"),
                         footer: tr("开启后，对应内容会随每次语音请求发送给当前模型的服务商，用于提高转录准确率。上下文只在你主动开始语音输入时通过辅助功能 API 读取；关闭后完全不发送。")) {
                SettingsRow(title: tr("使用当前 App 上下文"), subtitle: tr("App 名称与窗口标题")) {
                    Toggle("", isOn: $settings.useAppContext)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                CardDivider()
                SettingsRow(title: tr("读取光标附近文字"),
                            subtitle: tr("光标附近与页面中的文字")) {
                    Toggle("", isOn: $settings.readNearbyText)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                CardDivider()
                SettingsRow(title: tr("读取选中文字")) {
                    Toggle("", isOn: $settings.readSelectedText)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
            }

            SettingsCard(footer: tr("本应用不截图、不 OCR、不申请屏幕录制权限、不记录键盘输入。除录音音频与上方选择的上下文外，API Key、术语表、设置与历史记录全部只保存在这台 Mac 上。")) {
                SettingsRow(title: tr("数据边界"),
                            subtitle: tr("每次请求只发送：当次录音 + 上方勾选的上下文 + 术语提示")) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 语言卡片

private struct LanguageCard: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var newLanguage = ""

    private let recognitionOptions: [(String, String)] = [
        ("auto", tr("自动检测")), ("zh", tr("中文")), ("en", tr("英语")), ("ja", tr("日语")), ("ko", tr("韩语")),
        ("de", tr("德语")), ("fr", tr("法语")), ("es", tr("西班牙语")),
    ]

    var body: some View {
        SettingsCard(title: tr("语言")) {
            SettingsRow(title: tr("界面语言")) {
                Picker("", selection: $settings.appLanguage) {
                    ForEach(SettingsStore.AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden().fixedSize().id(L10n.effective)
            }
            CardDivider()
            SettingsRow(title: tr("语音识别语言")) {
                Picker("", selection: $settings.recognitionLanguage) {
                    ForEach(recognitionOptions, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                .labelsHidden().fixedSize().id(L10n.effective)
            }
            CardDivider()
            ForEach(Array(settings.targetLanguages.enumerated()), id: \.offset) { index, language in
                SettingsRow(title: index == 0 ? tr("翻译目标语言") : " ",
                            subtitle: nil) {
                    HStack(spacing: 8) {
                        if index == 0 {
                            Text(L10n.languageName(language)).font(.system(size: 13))
                            Text(tr("默认"))
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Text(L10n.languageName(language)).font(.system(size: 13)).foregroundStyle(.secondary)
                            Button(tr("设为默认")) {
                                var list = settings.targetLanguages
                                list.remove(at: index)
                                list.insert(language, at: 0)
                                settings.targetLanguages = list
                            }
                            .buttonStyle(.link).font(.system(size: 11))
                        }
                        Button {
                            var list = settings.targetLanguages
                            list.remove(at: index)
                            settings.targetLanguages = list
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(settings.targetLanguages.count <= 1)
                    }
                }
            }
            CardDivider()
            HStack(spacing: 8) {
                TextField(tr("添加翻译语言，如：日语"), text: $newLanguage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(addLanguage)
                Button(tr("添加"), action: addLanguage)
                    .controlSize(.small)
                    .disabled(newLanguage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private func addLanguage() {
        let language = newLanguage.trimmingCharacters(in: .whitespaces)
        guard !language.isEmpty, !settings.targetLanguages.contains(language) else { return }
        settings.targetLanguages.append(language)
        newLanguage = ""
    }
}

// MARK: - 模型

private struct ModelsPane: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var addingProvider = false
    @State private var editingProvider: ModelProvider?
    @State private var addingModel: ModelCapability?
    @State private var pendingProviderRemoval: ModelProvider?
    @State private var pendingModelRemoval: PendingModelRemoval?

    var body: some View {
        PaneScroll(title: tr("模型")) {
            SettingsCard(title: tr("服务商"),
                         footer: tr("API Key 只保存在 macOS 钥匙串中。添加服务商时无需选择模型。")) {
                ForEach(Array(settings.modelProviders.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { CardDivider() }
                    HStack(spacing: 10) {
                        ProviderIcon(kind: provider.kind, size: 26)
                        Text(provider.name)
                            .font(.system(size: 13))
                        Spacer(minLength: 12)
                        HStack(spacing: 9) {
                            Text(KeychainStore.loadAPIKey(providerID: provider.id) == nil ? tr("未设置") : "•••••••••••")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button(tr("修改")) { editingProvider = provider }
                                .controlSize(.small)
                            Button {
                                pendingProviderRemoval = provider
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .disabled(settings.modelProviders.count <= 1)
                            .help(tr("移除服务商"))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
                CardDivider()
                Button {
                    addingProvider = true
                } label: {
                    Label(tr("添加服务商"), systemImage: "plus")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }

            modelCard(capability: .transcription,
                      title: tr("语音识别模型"),
                      footer: tr("按从上到下的顺序尝试。当前模型失败时，自动切换到下一个。"),
                      models: settings.transcriptionModels)

            modelCard(capability: .language,
                      title: tr("语言模型"),
                      footer: tr("语音识别成功后，按从上到下的顺序尝试整理或翻译。"),
                      models: settings.languageModels)
        }
        .sheet(isPresented: $addingProvider) {
            ProviderKeySheet(provider: nil) { kind, key in
                _ = settings.addProvider(kind: kind, apiKey: key)
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderKeySheet(provider: provider) { _, key in
                _ = KeychainStore.saveAPIKey(key, providerID: provider.id)
            }
        }
        .sheet(item: $addingModel) { capability in
            AddModelSheet(capability: capability, providers: settings.modelProviders) { model in
                switch capability {
                case .transcription:
                    guard !settings.transcriptionModels.contains(where: {
                        $0.providerID == model.providerID && $0.modelID == model.modelID
                    }) else { return }
                    settings.transcriptionModels.append(model)
                case .language:
                    guard !settings.languageModels.contains(where: {
                        $0.providerID == model.providerID && $0.modelID == model.modelID
                    }) else { return }
                    settings.languageModels.append(model)
                }
            }
        }
        .confirmationDialog(tr("是否删除服务商？"),
                            isPresented: Binding(get: { pendingProviderRemoval != nil },
                                                 set: { if !$0 { pendingProviderRemoval = nil } }),
                            presenting: pendingProviderRemoval) { provider in
            Button(tr("删除服务商"), role: .destructive) {
                settings.removeProvider(provider)
                pendingProviderRemoval = nil
            }
            Button(tr("取消"), role: .cancel) { pendingProviderRemoval = nil }
        } message: { provider in
            Text(tr("将删除 %@ 的 API Key，并移除引用该服务商的模型。API Key 删除后无法找回。",
                    provider.name))
        }
        .confirmationDialog(tr("是否移除模型？"),
                            isPresented: Binding(get: { pendingModelRemoval != nil },
                                                 set: { if !$0 { pendingModelRemoval = nil } }),
                            presenting: pendingModelRemoval) { pending in
            Button(tr("移除模型"), role: .destructive) {
                remove(pending.capability, modelID: pending.model.id)
                pendingModelRemoval = nil
            }
            Button(tr("取消"), role: .cancel) { pendingModelRemoval = nil }
        } message: { pending in
            Text(tr("将从回退顺序中移除 %@。", pending.model.displayName))
        }
    }

    @ViewBuilder
    private func modelCard(capability: ModelCapability, title: String, footer: String,
                           models: [ConfiguredModel]) -> some View {
        SettingsCard(title: title, footer: footer) {
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                if index > 0 { CardDivider() }
                ModelPriorityRow(index: index, model: model,
                                 provider: settings.modelProviders.first { $0.id == model.providerID },
                                 capability: capability,
                                 count: models.count,
                                 moveUp: { move(capability, from: index, offset: -1) },
                                 moveDown: { move(capability, from: index, offset: 1) },
                                 remove: {
                                     pendingModelRemoval = PendingModelRemoval(
                                         capability: capability, model: model)
                                 })
            }
            CardDivider()
            Button {
                addingModel = capability
            } label: {
                Label(tr("添加模型"), systemImage: "plus")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .disabled(settings.modelProviders.isEmpty)
        }
    }

    private func move(_ capability: ModelCapability, from index: Int, offset: Int) {
        let target = index + offset
        switch capability {
        case .transcription:
            guard settings.transcriptionModels.indices.contains(index),
                  settings.transcriptionModels.indices.contains(target) else { return }
            settings.transcriptionModels.swapAt(index, target)
        case .language:
            guard settings.languageModels.indices.contains(index),
                  settings.languageModels.indices.contains(target) else { return }
            settings.languageModels.swapAt(index, target)
        }
    }

    private func remove(_ capability: ModelCapability, modelID: String) {
        switch capability {
        case .transcription:
            guard settings.transcriptionModels.count > 1 else { return }
            settings.transcriptionModels.removeAll { $0.id == modelID }
        case .language:
            guard settings.languageModels.count > 1 else { return }
            settings.languageModels.removeAll { $0.id == modelID }
        }
    }
}

private struct PendingModelRemoval: Identifiable {
    let capability: ModelCapability
    let model: ConfiguredModel
    var id: String { "\(capability.rawValue):\(model.id)" }
}

private struct ModelPriorityRow: View {
    let index: Int
    let model: ConfiguredModel
    let provider: ModelProvider?
    let capability: ModelCapability
    let count: Int
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.secondary.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.system(size: 13))
                HStack(spacing: 8) {
                    Text(provider?.name ?? tr("服务商已移除"))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let pricingSummary {
                        Text(pricingSummary)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                Button(action: moveUp) { Image(systemName: "chevron.up") }
                    .disabled(index == 0).help(tr("上移"))
                Button(action: moveDown) { Image(systemName: "chevron.down") }
                    .disabled(index + 1 >= count).help(tr("下移"))
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).disabled(count <= 1).help(tr("移除模型"))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var pricingSummary: String? {
        provider?.kind.pricingSummary(for: model.modelID, capability: capability)
    }
}

private struct ProviderKeySheet: View {
    let provider: ModelProvider?
    let onSave: (ModelProviderKind, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ModelProviderKind = .openAI
    @State private var key = ""
    @State private var validating = false
    @State private var errorText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(provider == nil ? tr("添加服务商") : tr("修改 API Key"))
                .font(.system(size: 18, weight: .semibold))

            if provider == nil {
                HStack(spacing: 12) {
                    ForEach(ModelProviderKind.allCases) { item in
                        providerCard(item)
                    }
                }
            } else {
                HStack(spacing: 9) {
                    ProviderIcon(kind: kind, size: 28)
                    Text(kind.displayName)
                        .font(.system(size: 14, weight: .semibold))
                }
            }

            Text(kind.introduction)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)

            SecureField(tr("API Key"), text: $key)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.apiKeyHelp)
                    .foregroundStyle(.secondary)
                Link(tr("获取 API Key"), destination: kind.apiKeyURL)
            }
            .font(.system(size: 11))
            if !errorText.isEmpty {
                Text(errorText).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(tr("取消")) { dismiss() }
                Button(tr("保存并验证"), action: validate)
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validating)
                if validating { ProgressView().controlSize(.small) }
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { if let provider { kind = provider.kind } }
    }

    private func providerCard(_ item: ModelProviderKind) -> some View {
        let selected = kind == item
        return Button {
            if kind != item {
                kind = item
                key = ""
                errorText = ""
            }
        } label: {
            HStack(spacing: 10) {
                ProviderIcon(kind: item, size: 28)
                Text(item.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.08)
                                  : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.65)
                                       : Color.primary.opacity(0.08),
                              lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private func validate() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        validating = true
        errorText = ""
        Task {
            do {
                switch kind {
                case .openAI: try await OpenAIClient(apiKey: candidate).validateKey()
                case .google: try await GeminiClient(apiKey: candidate).validateKey()
                }
                await MainActor.run {
                    onSave(kind, candidate)
                    validating = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    validating = false
                    errorText = tr("%@ 无法验证这个 API Key。", kind.displayName)
                }
            }
        }
    }
}

private struct AddModelSheet: View {
    let capability: ModelCapability
    let providers: [ModelProvider]
    let onAdd: (ConfiguredModel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var providerID = ""
    @State private var modelID = ""

    private var provider: ModelProvider? { providers.first { $0.id == providerID } }
    private var presets: [ModelPreset] { provider?.kind.presets(for: capability) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("添加模型")).font(.system(size: 18, weight: .semibold))
            Picker(tr("服务商"), selection: $providerID) {
                ForEach(providers) { provider in Text(provider.name).tag(provider.id) }
            }
            Picker(tr("模型"), selection: $modelID) {
                ForEach(presets) { preset in Text(preset.displayName).tag(preset.id) }
            }
            if let provider,
               let pricing = provider.kind.pricingSummary(for: modelID, capability: capability) {
                Text(pricing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(tr("取消")) { dismiss() }
                Button(tr("添加")) {
                    guard let preset = presets.first(where: { $0.id == modelID }) else { return }
                    onAdd(ConfiguredModel(providerID: providerID, modelID: preset.id,
                                          displayName: preset.displayName))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(provider == nil || modelID.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 400)
        .onAppear {
            if providerID.isEmpty { providerID = providers.first?.id ?? "" }
            modelID = presets.first?.id ?? ""
        }
        .onChange(of: providerID) { _, _ in modelID = presets.first?.id ?? "" }
    }
}

// MARK: - 术语表

private struct GlossaryPane: View {
    @ObservedObject var glossary = GlossaryStore.shared
    @ObservedObject var settings = SettingsStore.shared
    @State private var query = ""
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("术语表"))
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 34)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    TextField(tr("搜索"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                Button(tr("导入…"), action: importFile)
                    .controlSize(.regular)
            }

            SettingsCard {
                if glossary.search(query).isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 24))
                            .foregroundStyle(.quaternary)
                        Text(query.isEmpty ? tr("还没有术语。添加人名、项目名、常被识别错的词。") : tr("没有匹配的术语"))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(glossary.search(query).enumerated()), id: \.element.id) { index, term in
                                if index > 0 { CardDivider() }
                                GlossaryRow(term: term) { glossary.remove(term) }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                TextField(tr("添加术语"), text: $newTerm)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .onSubmit(add)
                Button(tr("添加"), action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // 「从修改中自动学习」功能尚未打磨好,暂不提供开关(功能已停用)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private func add() {
        glossary.add(newTerm)
        newTerm = ""
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.message = tr("选择一个文本文件，每行一个术语")
        guard panel.runModal() == .OK, let url = panel.url,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let count = glossary.importText(content)
        ToastPanel.show(message: tr("已导入 %lld 个术语", count))
    }
}

private struct GlossaryRow: View {
    let term: GlossaryStore.Term
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(term.text).font(.system(size: 13))
            if term.source == "learned" {
                Text(tr("已学习 ×%lld", term.confidence))
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.purple.opacity(0.12), in: Capsule())
                    .foregroundStyle(.purple)
            }
            Spacer()
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - 历史

private struct HistoryPane: View {
    @ObservedObject var history = HistoryStore.shared
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var log = LastRequestLog.shared
    @State private var copiedID: UUID?
    @State private var showDebug = false
    @State private var pendingDelete: HistoryStore.Entry?
    @State private var expandedIDs = Set<UUID>()
    /// 默认只渲染最近 10 条,点击「显示更多」再加载 20 条,避免长列表卡顿
    @State private var visibleCount = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("历史"))
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Toggle(tr("保留历史"), isOn: $settings.keepHistory)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 11))
                Button(tr("清空")) { history.clear() }
                    .controlSize(.small)
                    .disabled(history.entries.isEmpty)
            }
            .padding(.top, 34)

            if history.entries.isEmpty {
                SettingsCard {
                    VStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 24))
                            .foregroundStyle(.quaternary)
                        Text(tr("还没有转录记录"))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
                .frame(maxHeight: .infinity)
            } else {
                SettingsCard {
                    ScrollView {
                        VStack(spacing: 0) {
                            let visible = history.entries.prefix(visibleCount)
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { CardDivider() }
                                HistoryRow(entry: entry,
                                           expanded: expandedIDs.contains(entry.id),
                                           copied: copiedID == entry.id,
                                           canRetranscribe: history.canRetranscribe(entry.id),
                                           isRetranscribing: history.retranscribingID == entry.id,
                                           onToggle: {
                                               if expandedIDs.contains(entry.id) {
                                                   expandedIDs.remove(entry.id)
                                               } else {
                                                   expandedIDs.insert(entry.id)
                                               }
                                           },
                                           onCopy: {
                                               NSPasteboard.general.clearContents()
                                               NSPasteboard.general.setString(entry.text, forType: .string)
                                               copiedID = entry.id
                                           },
                                           onDelete: { pendingDelete = entry },
                                           onRetranscribe: {
                                               // 一次只跑一个重新转录;条目原地转圈,不再先删除
                                               guard history.retranscribingID == nil,
                                                     let wav = history.recordingData(for: entry.id) else { return }
                                               history.setRetranscribing(entry.id)
                                                let request = RetranscribeRequest(
                                                    entryID: entry.id,
                                                    wav: wav,
                                                    kind: entry.retry?.kind ?? "dictation",
                                                    target: entry.retry?.target,
                                                    retry: entry.retry)
                                               NotificationCenter.default.post(name: .retranscribeRequest,
                                                                               object: request)
                                           })
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                if history.entries.count > visibleCount {
                    Button(tr("显示更多")) { visibleCount += 20 }
                        .frame(maxWidth: .infinity)
                }
            }

            if settings.debugMode {
                DisclosureGroup(isExpanded: $showDebug) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            debugRow(tr("发送的上下文"), log.contextSummary)
                            debugRow(tr("术语提示"), log.termHint.isEmpty ? tr("（无）") : log.termHint)
                            debugRow(tr("文字插入"), log.insertTrace.isEmpty ? tr("（无）") : log.insertTrace)
                            debugRow(tr("错误"), log.lastError ?? tr("（无）"))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(maxHeight: 130)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } label: {
                    Text(tr("最近一次请求详情"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .confirmationDialog(tr("是否删除？"),
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { entry in
            Button(tr("删除"), role: .destructive) {
                history.remove(entry)
                expandedIDs.remove(entry.id)
                pendingDelete = nil
            }
            Button(tr("取消"), role: .cancel) { pendingDelete = nil }
        }
    }

    private func debugRow(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(content)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

// MARK: - 请求

private struct RequestPane: View {
    @ObservedObject var log = LastRequestLog.shared
    @State private var copiedSection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("请求"))
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                if log.timestamp != nil {
                    Text(tr("最近一次：%@", log.timestamp!.formatted(date: .abbreviated, time: .standard)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(tr("复制全部")) { copy(allText(), id: "all") }
                        .controlSize(.small)
                }
            }
            .padding(.top, 34)

            if log.timestamp == nil {
                SettingsCard {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 24))
                            .foregroundStyle(.quaternary)
                        Text(tr("还没有发送过请求"))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        payloadCard(tr("系统提示词"), log.systemPrompt)
                        payloadCard(tr("用户提示词"), log.userPrompt)
                        payloadCard(tr("转录原文"), log.transcript)
                        payloadCard(tr("模型回复"), log.response.isEmpty ? tr("（无，请求失败或未到达整理阶段）") : log.response)
                        payloadCard(tr("发送的上下文"), log.contextSummary)
                        payloadCard(tr("术语提示"), log.termHint.isEmpty ? tr("（无）") : log.termHint)
                        payloadCard(tr("文字插入"), log.insertTrace.isEmpty ? tr("（无）") : log.insertTrace)
                        if let error = log.lastError {
                            payloadCard(tr("错误"), error)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private func payloadCard(_ title: String, _ content: String) -> some View {
        SettingsCard(title: title) {
            HStack {
                Spacer()
                Button {
                    copy(content, id: title)
                } label: {
                    Label(copiedSection == title ? tr("已复制") : tr("复制"),
                          systemImage: copiedSection == title ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(copiedSection == title ? Color.green : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            ScrollView {
                Text(content.isEmpty ? tr("（空）") : content)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 160)
        }
    }

    private func allText() -> String {
        var parts: [String] = []
        parts.append(tr("【系统提示词】") + "\n" + log.systemPrompt)
        parts.append(tr("【用户提示词】") + "\n" + log.userPrompt)
        parts.append(tr("【转录原文】") + "\n" + log.transcript)
        parts.append(tr("【模型回复】") + "\n" + log.response)
        return parts.joined(separator: "\n\n")
    }

    private func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedSection = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedSection == id { copiedSection = nil }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryStore.Entry
    let expanded: Bool
    let copied: Bool
    /// 该条目是否保留了可重新转录的录音(由 HistoryStore 统一管理)
    let canRetranscribe: Bool
    /// 该条目正在重新转录(显示旋转指示)
    let isRetranscribing: Bool
    let onToggle: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    var onRetranscribe: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Button(action: onToggle) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 10, height: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            if entry.failed {
                                Text(tr("转录失败"))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.red)
                            } else {
                                Text(expanded ? entry.text : entry.text.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 12.5))
                                    .lineLimit(expanded ? nil : 2)
                                    .truncationMode(.tail)
                                    .multilineTextAlignment(.leading)
                            }
                            HStack(spacing: 6) {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                Text("·")
                                Text(entry.mode)
                                if let app = entry.appName {
                                    Text("·")
                                    Text(app)
                                }
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? tr("收起详情") : tr("展开详情"))

                // 按钮常驻,避免 hover 触发文字重排;操作区不触发展开。
                HStack(spacing: 4) {
                    if isRetranscribing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 24, height: 24)
                    } else if canRetranscribe {
                        IconButton(systemName: "arrow.clockwise",
                                   tint: .secondary,
                                   help: tr("重新转录"),
                                   action: { onRetranscribe?() })
                    }
                    if !entry.failed {
                        IconButton(systemName: copied ? "checkmark" : "doc.on.doc",
                                   tint: copied ? .green : .secondary,
                                   help: copied ? tr("已复制") : tr("复制"),
                                   action: onCopy)
                    }
                    IconButton(systemName: "trash",
                               tint: .secondary,
                               help: tr("删除"),
                               action: onDelete)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if expanded {
                Divider().padding(.leading, 30).opacity(0.55)
                HistoryModelDetails(entry: entry)
                    .padding(.leading, 30)
                    .padding(.trailing, 12)
                    .padding(.vertical, 10)
            }
        }
    }
}

private struct HistoryModelDetails: View {
    let entry: HistoryStore.Entry

    private var transcriptionAttempts: [ModelAttempt] {
        entry.modelAttempts.filter { $0.capability == .transcription }
    }

    private var processingAttempts: [ModelAttempt] {
        entry.modelAttempts.filter { $0.capability == .language }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if entry.modelAttempts.isEmpty && entry.detailMessage == nil {
                Text(tr("旧记录没有模型信息。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                if !transcriptionAttempts.isEmpty {
                    attemptSection(title: tr("语音识别模型"), attempts: transcriptionAttempts)
                }
                if !processingAttempts.isEmpty {
                    attemptSection(title: tr("后处理模型"), attempts: processingAttempts)
                }
                if let message = entry.detailMessage {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.failed ? tr("错误") : tr("处理说明"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(entry.failed ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attemptSection(title: String, attempts: [ModelAttempt]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(attempts.enumerated()), id: \.element.id) { index, attempt in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color.secondary.opacity(0.11), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(attempt.modelName)
                                .font(.system(size: 11.5, weight: .medium))
                            Text(attempt.succeeded ? tr("成功") : tr("失败"))
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(attempt.succeeded ? Color.green : Color.red)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background((attempt.succeeded ? Color.green : Color.red).opacity(0.10), in: Capsule())
                        }
                        Text("\(attempt.providerName) · \(attempt.modelID)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        if let reason = attempt.failureReason {
                            Text(reason)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

/// 小尺寸图标按钮:固定占位,hover 时浮现浅色背景
private struct IconButton: View {
    let systemName: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - 关于

private struct AboutPane: View {
    private static let repoURL = URL(string: "https://github.com/Zhangyanbo/OpenVoice")!
    private static let issueURL = URL(string: "https://github.com/Zhangyanbo/OpenVoice/issues/new")!

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, build != version {
            return tr("版本 %@（%@）", version, build)
        }
        return tr("版本 %@", version)
    }

    var body: some View {
        PaneScroll(title: tr("关于")) {
            VStack(spacing: 18) {
                // 头部:图标 + 名称 + 版本
                VStack(spacing: 8) {
                    AppMark(size: 72)
                    Text("OpenVoice")
                        .font(.system(size: 17, weight: .bold))
                    Text(versionText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)

                SettingsCard {
                    Link(destination: Self.repoURL) {
                        SettingsRow(title: "GitHub", subtitle: tr("查看源代码与文档")) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    CardDivider()
                    Link(destination: Self.issueURL) {
                        SettingsRow(title: tr("问题反馈"), subtitle: tr("在 GitHub 上提交 Issue")) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Text(tr("光标放到任意 App → 按 Fn → 说话 → 再按 Fn → 文字出现在光标处。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
