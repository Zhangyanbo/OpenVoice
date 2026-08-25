import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口:左侧图标侧边栏 + 右侧卡片式分区。
/// 视觉语言与悬浮条一致:克制、现代、低噪。
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private let nav = SettingsNav()

    enum Tab: String, CaseIterable {
        case general, personalization, privacy, glossary, history, request, about

        var title: String {
            switch self {
            case .general: return tr("通用")
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
            window.center()
            self.window = window
        }
        if let tab { nav.tab = tab }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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

            OpenAICard()
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
                         footer: tr("开启后，对应内容会随每次语音请求发送给 OpenAI 用于提高转录准确率。上下文只在你主动开始语音输入时通过辅助功能 API 读取；关闭后完全不发送。")) {
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

// MARK: - OpenAI 卡片

private struct OpenAICard: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var editingKey = false
    @State private var keyInput = ""
    @State private var status = ""
    @State private var validating = false

    private let transcribeOptions = ["", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
    private let llmOptions = ["", "gpt-5.6-luna", "gpt-5-nano", "gpt-4.1-nano", "gpt-5.4-mini"]

    var body: some View {
        SettingsCard(title: "OpenAI", footer: tr("默认模型即当前推荐，普通使用无需修改。API Key 只保存在 macOS 钥匙串。")) {
            if editingKey {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField(tr("API Key(sk-…)"), text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button(tr("保存并验证")) { saveKey() }
                            .controlSize(.small)
                            .disabled(keyInput.isEmpty || validating)
                        Button(tr("取消")) {
                            editingKey = false; keyInput = ""; status = ""
                        }
                        .controlSize(.small)
                        if validating { ProgressView().controlSize(.small) }
                        if !status.isEmpty {
                            Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                SettingsRow(title: "API Key",
                            subtitle: status.isEmpty ? nil : status) {
                    HStack(spacing: 10) {
                        Text(KeychainStore.loadAPIKey() != nil ? "•••••••••••" : tr("未设置"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button(tr("修改")) { editingKey = true }
                            .controlSize(.small)
                    }
                }
            }
            CardDivider()
            SettingsRow(title: tr("语音识别模型")) {
                Picker("", selection: $settings.transcribeModel) {
                    ForEach(transcribeOptions, id: \.self) { model in
                        Text(model.isEmpty ? tr("默认（%@）", SettingsStore.defaultTranscribeModel) : model).tag(model)
                    }
                }
                .labelsHidden().fixedSize().id(L10n.effective)
            }
            CardDivider()
            SettingsRow(title: tr("语言模型")) {
                Picker("", selection: $settings.llmModel) {
                    ForEach(llmOptions, id: \.self) { model in
                        Text(model.isEmpty ? tr("默认（%@）", SettingsStore.defaultLLMModel) : model).tag(model)
                    }
                }
                .labelsHidden().fixedSize().id(L10n.effective)
            }
        }
    }

    private func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        validating = true
        status = tr("正在验证…")
        Task {
            do {
                try await OpenAIClient(apiKey: key).validateKey()
                _ = KeychainStore.saveAPIKey(key)
                await MainActor.run {
                    validating = false; editingKey = false; keyInput = ""
                    status = tr("已保存到 Keychain")
                }
            } catch {
                await MainActor.run {
                    validating = false
                    status = tr("OpenAI 无法验证这个 API Key")
                }
            }
        }
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
                                           copied: copiedID == entry.id,
                                           canRetranscribe: history.canRetranscribe(entry.id),
                                           isRetranscribing: history.retranscribingID == entry.id,
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
    let copied: Bool
    /// 该条目是否保留了可重新转录的录音(由 HistoryStore 统一管理)
    let canRetranscribe: Bool
    /// 该条目正在重新转录(显示旋转指示)
    let isRetranscribing: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    var onRetranscribe: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                // 只显示前两行,超出部分以尾部省略号标记;完整内容用旁边的复制按钮获取。
                // 不开 textSelection:点击选中会导致文本重排(省略号消失、整段展开盖住 meta 信息)
                if entry.failed {
                    Text(tr("转录失败"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.red)
                } else {
                    // 预览忽略换行符,避免第一行很短时浪费宝贵的两行空间
                    Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12.5))
                        .lineLimit(2)
                        .truncationMode(.tail)
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
            Spacer(minLength: 12)
            // 按钮常驻,避免 hover 触发文字重排;复制只用图标
            HStack(spacing: 4) {
                // 顺序固定:重新转录、复制、删除 —— 无论某行缺哪个按钮,右侧删除的位置都不变
                // 只有保留了录音的条目才有重新转录(最近 10 条)
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
                // 失败行没有可复制的正文
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
        .contentShape(Rectangle())
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
