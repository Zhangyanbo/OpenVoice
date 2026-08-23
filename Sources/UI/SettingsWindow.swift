import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口。三个标签:通用(含快捷键/语言/上下文/OpenAI 等常用项)、术语表、历史。
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private let nav = SettingsNav()

    enum Tab: String {
        case general, glossary, history
    }

    func show(tab: Tab? = nil) {
        if window == nil {
            let content = SettingsRootView(nav: nav)
            let hosting = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: hosting)
            window.title = "OpenVoiceInput 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 600, height: 520))
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

struct SettingsRootView: View {
    @ObservedObject var nav: SettingsNav

    var body: some View {
        TabView(selection: $nav.tab) {
            GeneralTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsWindowController.Tab.general)
            GlossaryTab()
                .tabItem { Label("术语表", systemImage: "character.book.closed") }
                .tag(SettingsWindowController.Tab.glossary)
            HistoryTab()
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsWindowController.Tab.history)
        }
        .frame(width: 600, height: 520)
    }
}

// MARK: - 通用(常用设置集中在一页,分区滚动)

private struct GeneralTab: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时启动", isOn: $settings.launchAtLogin)
                Toggle("播放提示音", isOn: $settings.playSound)
                Toggle("显示语音悬浮条", isOn: $settings.showPanel)
                Button("重置悬浮条位置") { settings.clearPanelOrigin() }
            }

            Section("快捷键") {
                Picker("语音输入", selection: $settings.primaryKey) {
                    ForEach(SettingsStore.TriggerKey.allCases.filter { $0 != .none }) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                Picker("备用快捷键", selection: $settings.altKey) {
                    ForEach(SettingsStore.TriggerKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                LabeledContent("翻译", value: "\(settings.primaryKey.displayName) + 左 Shift")
                Text("若使用 Fn,请在 系统设置 → 键盘 中把「按下 🌐 键时」设为「无操作」,避免与系统听写冲突。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LanguageSection()

            Section("上下文") {
                Toggle("使用当前 App 上下文", isOn: $settings.useAppContext)
                Toggle("读取光标附近文字", isOn: $settings.readNearbyText)
                Toggle("读取选中文字", isOn: $settings.readSelectedText)
                Text("上下文只在你主动开始语音输入时通过辅助功能 API 读取。本应用不截图、不 OCR、不申请屏幕录制权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            OpenAISection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - 语言分区

private struct LanguageSection: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var newLanguage = ""

    private let recognitionOptions: [(String, String)] = [
        ("auto", "自动检测"), ("zh", "中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"),
        ("de", "德语"), ("fr", "法语"), ("es", "西班牙语"),
    ]

    var body: some View {
        Section("语言") {
            Picker("语音识别语言", selection: $settings.recognitionLanguage) {
                ForEach(recognitionOptions, id: \.0) { code, name in
                    Text(name).tag(code)
                }
            }

            ForEach(Array(settings.targetLanguages.enumerated()), id: \.offset) { index, language in
                HStack {
                    Text(index == 0 ? "翻译目标语言(默认):\(language)" : "候选:\(language)")
                    Spacer()
                    if index > 0 {
                        Button("设为默认") {
                            var list = settings.targetLanguages
                            list.remove(at: index)
                            list.insert(language, at: 0)
                            settings.targetLanguages = list
                        }
                        .buttonStyle(.link)
                    }
                    Button(role: .destructive) {
                        var list = settings.targetLanguages
                        list.remove(at: index)
                        settings.targetLanguages = list
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                    .disabled(settings.targetLanguages.count <= 1)
                }
            }
            HStack {
                TextField("添加翻译语言,如:日语", text: $newLanguage)
                    .onSubmit(addLanguage)
                Button("添加", action: addLanguage)
                    .disabled(newLanguage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addLanguage() {
        let language = newLanguage.trimmingCharacters(in: .whitespaces)
        guard !language.isEmpty, !settings.targetLanguages.contains(language) else { return }
        settings.targetLanguages.append(language)
        newLanguage = ""
    }
}

// MARK: - OpenAI 分区

private struct OpenAISection: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var editingKey = false
    @State private var keyInput = ""
    @State private var status = ""
    @State private var validating = false

    private let transcribeOptions = ["", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
    private let llmOptions = ["", "gpt-5.6-luna", "gpt-5-nano", "gpt-4.1-nano", "gpt-5.4-mini"]

    var body: some View {
        Section("OpenAI") {
            if editingKey {
                SecureField("API Key(sk-…)", text: $keyInput)
                HStack {
                    Button("保存并验证") { saveKey() }
                        .disabled(keyInput.isEmpty || validating)
                    Button("取消") {
                        editingKey = false
                        keyInput = ""
                        status = ""
                    }
                    if validating { ProgressView().controlSize(.small) }
                }
            } else {
                LabeledContent("API Key") {
                    HStack {
                        Text(KeychainStore.loadAPIKey() != nil ? "•••••••••••" : "未设置")
                        Button("修改") { editingKey = true }
                    }
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            Picker("语音识别模型", selection: $settings.transcribeModel) {
                ForEach(transcribeOptions, id: \.self) { model in
                    Text(model.isEmpty ? "默认(\(SettingsStore.defaultTranscribeModel))" : model).tag(model)
                }
            }
            Picker("语言模型", selection: $settings.llmModel) {
                ForEach(llmOptions, id: \.self) { model in
                    Text(model.isEmpty ? "默认(\(SettingsStore.defaultLLMModel))" : model).tag(model)
                }
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
                    validating = false
                    editingKey = false
                    keyInput = ""
                    status = "已保存到 Keychain。"
                }
            } catch {
                await MainActor.run {
                    validating = false
                    status = "OpenAI 无法验证这个 API Key。"
                }
            }
        }
    }
}

// MARK: - 术语表

private struct GlossaryTab: View {
    @ObservedObject var glossary = GlossaryStore.shared
    @ObservedObject var settings = SettingsStore.shared
    @State private var query = ""
    @State private var newTerm = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("搜索", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("导入…", action: importFile)
            }

            List {
                ForEach(glossary.search(query)) { term in
                    HStack {
                        Text(term.text)
                        if term.source == "learned" {
                            Text("已学习 ×\(term.confidence)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            glossary.remove(term)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                TextField("添加术语,如:MacroNet", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("添加", action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Toggle("从修改中自动学习", isOn: $settings.autoLearn)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
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

// MARK: - 历史

private struct HistoryTab: View {
    @ObservedObject var history = HistoryStore.shared
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var log = LastRequestLog.shared
    @State private var copiedID: UUID?
    @State private var showDebug = false

    var body: some View {
        VStack(spacing: 8) {
            if history.entries.isEmpty {
                Spacer()
                Text("还没有转录记录")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(history.entries) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.text)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                                Text(subtitle(for: entry))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(copiedID == entry.id ? "已复制" : "复制") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                                copiedID = entry.id
                            }
                            .controlSize(.small)
                            Button(role: .destructive) {
                                history.remove(entry)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            HStack {
                Toggle("保留转录历史", isOn: $settings.keepHistory)
                Spacer()
                Button("清空历史", role: .destructive) { history.clear() }
                    .disabled(history.entries.isEmpty)
            }

            DisclosureGroup("最近一次请求详情(排查用)", isExpanded: $showDebug) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        debugRow("发送的上下文", log.contextSummary)
                        debugRow("术语提示", log.termHint.isEmpty ? "(无)" : log.termHint)
                        debugRow("文字插入", log.insertTrace.isEmpty ? "(无)" : log.insertTrace)
                        debugRow("错误", log.lastError ?? "(无)")
                        Text("历史只保存在这台 Mac 上;除音频与上述上下文外,没有数据离开本机。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
        .padding()
    }

    private func subtitle(for entry: HistoryStore.Entry) -> String {
        var parts = [entry.date.formatted(date: .abbreviated, time: .shortened), entry.mode]
        if let app = entry.appName { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    private func debugRow(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold())
            Text(content)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
