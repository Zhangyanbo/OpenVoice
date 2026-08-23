import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口(spec §17)。菜单栏 App,窗口按需创建。
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let content = SettingsRootView()
            let hosting = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: hosting)
            window.title = "OpenVoiceInput 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 560, height: 420))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("通用", systemImage: "gearshape") }
            HotkeyTab().tabItem { Label("快捷键", systemImage: "keyboard") }
            LanguageTab().tabItem { Label("语言", systemImage: "globe") }
            ContextTab().tabItem { Label("上下文", systemImage: "text.cursor") }
            GlossaryTab().tabItem { Label("术语表", systemImage: "character.book.closed") }
            OpenAITab().tabItem { Label("OpenAI", systemImage: "key") }
            AdvancedTab().tabItem { Label("高级", systemImage: "eye") }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - 通用

private struct GeneralTab: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        Form {
            Toggle("登录时启动", isOn: $settings.launchAtLogin)
            Toggle("播放提示音", isOn: $settings.playSound)
            Toggle("显示语音悬浮条", isOn: $settings.showPanel)
            Button("重置悬浮条位置") { settings.clearPanelOrigin() }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 快捷键

private struct HotkeyTab: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        Form {
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
            Text("提示:若使用 Fn,请在 系统设置 → 键盘 中把「按下 🌐 键时」设为「无操作」,避免与系统听写冲突。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 语言

private struct LanguageTab: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var newLanguage = ""

    private let recognitionOptions: [(String, String)] = [
        ("auto", "自动检测"), ("zh", "中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"),
        ("de", "德语"), ("fr", "法语"), ("es", "西班牙语"),
    ]

    var body: some View {
        Form {
            Picker("语音识别语言", selection: $settings.recognitionLanguage) {
                ForEach(recognitionOptions, id: \.0) { code, name in
                    Text(name).tag(code)
                }
            }

            Section("翻译目标语言(第一项为默认)") {
                List {
                    ForEach(Array(settings.targetLanguages.enumerated()), id: \.offset) { index, language in
                        HStack {
                            Text("\(index + 1). \(language)")
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
                }
                .frame(minHeight: 100)
                HStack {
                    TextField("添加语言,如:日语", text: $newLanguage)
                        .onSubmit(addLanguage)
                    Button("添加", action: addLanguage)
                        .disabled(newLanguage.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func addLanguage() {
        let language = newLanguage.trimmingCharacters(in: .whitespaces)
        guard !language.isEmpty, !settings.targetLanguages.contains(language) else { return }
        settings.targetLanguages.append(language)
        newLanguage = ""
    }
}

// MARK: - 上下文

private struct ContextTab: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        Form {
            Toggle("使用当前 App 上下文", isOn: $settings.useAppContext)
            Toggle("读取光标附近文字", isOn: $settings.readNearbyText)
            Toggle("读取选中文字", isOn: $settings.readSelectedText)
            Text("上下文只在你主动开始语音输入时通过辅助功能 API 读取,随请求发送给 OpenAI。本应用不截图、不 OCR、不申请屏幕录制权限。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
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

// MARK: - OpenAI

private struct OpenAITab: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var editingKey = false
    @State private var keyInput = ""
    @State private var status = ""
    @State private var validating = false

    private let transcribeOptions = ["", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
    private let llmOptions = ["", "gpt-5.6-luna", "gpt-5-nano", "gpt-4.1-nano", "gpt-5.4-mini"]

    var body: some View {
        Form {
            Section("API Key") {
                if editingKey {
                    SecureField("sk-…", text: $keyInput)
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
                    HStack {
                        Text(KeychainStore.loadAPIKey() != nil ? "•••••••••••" : "未设置")
                        Spacer()
                        Button("修改") { editingKey = true }
                    }
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("模型(默认即推荐,普通用户无需修改)") {
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
        .formStyle(.grouped)
        .padding()
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

// MARK: - 高级(spec §18「查看本次发送的上下文」)

private struct AdvancedTab: View {
    @ObservedObject var log = LastRequestLog.shared

    var body: some View {
        Form {
            Section("上次请求实际发送给 OpenAI 的内容") {
                if let timestamp = log.timestamp {
                    LabeledContent("时间", value: timestamp.formatted(date: .omitted, time: .standard))
                }
                LabeledContent("上下文文字") {
                    Text(log.contextSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LabeledContent("术语提示") {
                    Text(log.termHint.isEmpty ? "(无)" : log.termHint)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section("最近一次错误") {
                if let error = log.lastError {
                    if let at = log.lastErrorAt {
                        LabeledContent("时间", value: at.formatted(date: .omitted, time: .standard))
                    }
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("(无)").foregroundStyle(.secondary)
                }
            }
            Text("除以上内容与录音音频外,没有任何数据离开这台 Mac。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}
