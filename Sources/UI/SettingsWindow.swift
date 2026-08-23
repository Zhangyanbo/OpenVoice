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
        case general, privacy, glossary, history

        var title: String {
            switch self {
            case .general: return "通用"
            case .privacy: return "隐私"
            case .glossary: return "术语表"
            case .history: return "历史"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .privacy: return "hand.raised.fill"
            case .glossary: return "character.book.closed.fill"
            case .history: return "clock.arrow.circlepath"
            }
        }

        var iconColor: Color {
            switch self {
            case .general: return Color(red: 0.42, green: 0.48, blue: 0.56)
            case .privacy: return Color(red: 0.25, green: 0.55, blue: 0.9)
            case .glossary: return Color(red: 0.95, green: 0.61, blue: 0.19)
            case .history: return Color(red: 0.56, green: 0.45, blue: 0.86)
            }
        }
    }

    func show(tab: Tab? = nil) {
        if window == nil {
            let content = SettingsRootView(nav: nav)
            let hosting = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: hosting)
            window.title = "OpenVoiceInput 设置"
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

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch nav.tab {
                case .general: GeneralPane()
                case .privacy: PrivacyPane()
                case .glossary: GlossaryPane()
                case .history: HistoryPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 720, height: 520)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 给交通灯留位
            Spacer().frame(height: 40)

            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 0.95),
                                                Color(red: 0.25, green: 0.4, blue: 0.85)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("OpenVoiceInput")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)

            ForEach(SettingsWindowController.Tab.allCases, id: \.self) { tab in
                SidebarItem(tab: tab, selected: nav.tab == tab) {
                    nav.tab = tab
                }
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 178)
        .background(.regularMaterial)
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
        PaneScroll(title: "通用") {
            SettingsCard {
                SettingsRow(title: "登录时启动") {
                    Toggle("", isOn: $settings.launchAtLogin)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                CardDivider()
                SettingsRow(title: "播放提示音", subtitle: "录音开始时") {
                    Toggle("", isOn: $settings.playSound)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                CardDivider()
                SettingsRow(title: "按键音效", subtitle: "结束录音的按键反馈") {
                    Toggle("", isOn: $settings.keyPressSound)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                CardDivider()
                SettingsRow(title: "显示语音悬浮条", subtitle: "悬浮条可拖动,位置会被记住") {
                    HStack(spacing: 10) {
                        Button("重置位置") { settings.clearPanelOrigin() }
                            .controlSize(.small)
                        Toggle("", isOn: $settings.showPanel)
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                }
                CardDivider()
                SettingsRow(title: "Debug", subtitle: "在历史页显示最近一次请求详情") {
                    Toggle("", isOn: $settings.debugMode)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
            }

            SettingsCard(title: "快捷键",
                         footer: "若使用 Fn,请在 系统设置 → 键盘 中把「按下 🌐 键时」设为「无操作」,避免与系统听写冲突。") {
                SettingsRow(title: "语音输入") {
                    Picker("", selection: $settings.primaryKey) {
                        ForEach(SettingsStore.TriggerKey.allCases.filter { $0 != .none }) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                CardDivider()
                SettingsRow(title: "备用快捷键") {
                    Picker("", selection: $settings.altKey) {
                        ForEach(SettingsStore.TriggerKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                CardDivider()
                SettingsRow(title: "翻译") {
                    Text("\(settings.primaryKey.displayName) + 左 Shift")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            LanguageCard()

            OpenAICard()
        }
    }
}

// MARK: - 隐私

private struct PrivacyPane: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        PaneScroll(title: "隐私") {
            SettingsCard(title: "上下文",
                         footer: "开启后,对应内容会随每次语音请求发送给 OpenAI 用于提高转录准确率。上下文只在你主动开始语音输入时通过辅助功能 API 读取;关闭后完全不发送。") {
                SettingsRow(title: "使用当前 App 上下文", subtitle: "App 名称与窗口标题") {
                    Toggle("", isOn: $settings.useAppContext)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                CardDivider()
                SettingsRow(title: "读取光标附近文字") {
                    Toggle("", isOn: $settings.readNearbyText)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                CardDivider()
                SettingsRow(title: "读取选中文字") {
                    Toggle("", isOn: $settings.readSelectedText)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
            }

            SettingsCard(footer: "本应用不截图、不 OCR、不申请屏幕录制权限、不记录键盘输入。除录音音频与上方选择的上下文外,API Key、术语表、设置与历史记录全部只保存在这台 Mac 上。") {
                SettingsRow(title: "数据边界",
                            subtitle: "每次请求只发送:当次录音 + 上方勾选的上下文 + 术语提示") {
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
        ("auto", "自动检测"), ("zh", "中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"),
        ("de", "德语"), ("fr", "法语"), ("es", "西班牙语"),
    ]

    var body: some View {
        SettingsCard(title: "语言") {
            SettingsRow(title: "语音识别语言") {
                Picker("", selection: $settings.recognitionLanguage) {
                    ForEach(recognitionOptions, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                .labelsHidden().fixedSize()
            }
            CardDivider()
            ForEach(Array(settings.targetLanguages.enumerated()), id: \.offset) { index, language in
                SettingsRow(title: index == 0 ? "翻译目标语言" : " ",
                            subtitle: nil) {
                    HStack(spacing: 8) {
                        if index == 0 {
                            Text(language).font(.system(size: 13))
                            Text("默认")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Text(language).font(.system(size: 13)).foregroundStyle(.secondary)
                            Button("设为默认") {
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
                TextField("添加翻译语言,如:日语", text: $newLanguage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(addLanguage)
                Button("添加", action: addLanguage)
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
        SettingsCard(title: "OpenAI", footer: "默认模型即当前推荐,普通使用无需修改。API Key 只保存在 macOS Keychain。") {
            if editingKey {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("API Key(sk-…)", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存并验证") { saveKey() }
                            .controlSize(.small)
                            .disabled(keyInput.isEmpty || validating)
                        Button("取消") {
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
                        Text(KeychainStore.loadAPIKey() != nil ? "•••••••••••" : "未设置")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("修改") { editingKey = true }
                            .controlSize(.small)
                    }
                }
            }
            CardDivider()
            SettingsRow(title: "语音识别模型") {
                Picker("", selection: $settings.transcribeModel) {
                    ForEach(transcribeOptions, id: \.self) { model in
                        Text(model.isEmpty ? "默认(\(SettingsStore.defaultTranscribeModel))" : model).tag(model)
                    }
                }
                .labelsHidden().fixedSize()
            }
            CardDivider()
            SettingsRow(title: "语言模型") {
                Picker("", selection: $settings.llmModel) {
                    ForEach(llmOptions, id: \.self) { model in
                        Text(model.isEmpty ? "默认(\(SettingsStore.defaultLLMModel))" : model).tag(model)
                    }
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    private func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        validating = true
        status = "正在验证…"
        Task {
            do {
                try await OpenAIClient(apiKey: key).validateKey()
                _ = KeychainStore.saveAPIKey(key)
                await MainActor.run {
                    validating = false; editingKey = false; keyInput = ""
                    status = "已保存到 Keychain"
                }
            } catch {
                await MainActor.run {
                    validating = false
                    status = "OpenAI 无法验证这个 API Key"
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
            Text("术语表")
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 34)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    TextField("搜索", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                Button("导入…", action: importFile)
                    .controlSize(.regular)
            }

            SettingsCard {
                if glossary.search(query).isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 24))
                            .foregroundStyle(.quaternary)
                        Text(query.isEmpty ? "还没有术语。添加人名、项目名、常被识别错的词。" : "没有匹配的术语")
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
                TextField("添加术语", text: $newTerm)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .onSubmit(add)
                Button("添加", action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Toggle("从修改中自动学习:语音输入后你立即手动纠正的词,会自动加入术语表", isOn: $settings.autoLearn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
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
        panel.message = "选择一个文本文件,每行一个术语"
        guard panel.runModal() == .OK, let url = panel.url,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let count = glossary.importText(content)
        ToastPanel.show(message: "已导入 \(count) 个术语")
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
                Text("已学习 ×\(term.confidence)")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("历史")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Toggle("保留历史", isOn: $settings.keepHistory)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 11))
                Button("清空") { history.clear() }
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
                        Text("还没有转录记录")
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
                            ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { CardDivider() }
                                HistoryRow(entry: entry,
                                           copied: copiedID == entry.id,
                                           onCopy: {
                                               NSPasteboard.general.clearContents()
                                               NSPasteboard.general.setString(entry.text, forType: .string)
                                               copiedID = entry.id
                                           },
                                           onDelete: { pendingDelete = entry })
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            if settings.debugMode {
                DisclosureGroup(isExpanded: $showDebug) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            debugRow("发送的上下文", log.contextSummary)
                            debugRow("术语提示", log.termHint.isEmpty ? "(无)" : log.termHint)
                            debugRow("文字插入", log.insertTrace.isEmpty ? "(无)" : log.insertTrace)
                            debugRow("错误", log.lastError ?? "(无)")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(maxHeight: 130)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } label: {
                    Text("最近一次请求详情")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .confirmationDialog("是否删除?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { entry in
            Button("删除", role: .destructive) {
                history.remove(entry)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
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

private struct HistoryRow: View {
    let entry: HistoryStore.Entry
    let copied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                // 只显示前两行,超出部分以尾部省略号标记;复制取的是完整内容
                Text(entry.text)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
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
                IconButton(systemName: copied ? "checkmark" : "doc.on.doc",
                           tint: copied ? .green : .secondary,
                           help: copied ? "已复制" : "复制",
                           action: onCopy)
                IconButton(systemName: "trash",
                           tint: .secondary,
                           help: "删除",
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
