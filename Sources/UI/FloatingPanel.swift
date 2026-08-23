import AppKit
import SwiftUI
import Combine

/// 悬浮条状态模型
final class PanelModel: ObservableObject {
    enum Phase {
        case listening
        case transcribing
        case error(String)
    }

    @Published var phase: Phase = .listening
    @Published var level: Float = 0
    /// 非空表示翻译模式:(当前目标语言, 可选语言列表)
    @Published var translation: (current: String, options: [String])?

    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDismissError: (() -> Void)?
    var onLanguageChange: ((String) -> Void)?
}

/// 悬浮条窗口控制器(spec §4):
/// - .nonactivatingPanel,不抢当前 App 的键盘焦点;
/// - 浮在普通窗口之上,跟随当前使用的窗口所在屏幕;
/// - 可拖动,位置持久化;用完自动消失。
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var hostView: NSHostingView<RecordingBarView>?
    private let model = PanelModel()
    private let settings = SettingsStore.shared
    /// 拖动持久化与程序化摆放会同时触发 windowDidMove,区分之
    private var programmaticMove = false

    var onCancel: (() -> Void)? {
        get { model.onCancel }
        set { model.onCancel = newValue }
    }
    var onRetry: (() -> Void)? {
        get { model.onRetry }
        set { model.onRetry = newValue }
    }
    var onDismissError: (() -> Void)? {
        get { model.onDismissError }
        set { model.onDismissError = newValue }
    }
    var onLanguageChange: ((String) -> Void)? {
        get { model.onLanguageChange }
        set { model.onLanguageChange = newValue }
    }

    func showListening(translation: (String, [String])?) {
        model.phase = .listening
        model.level = 0
        model.translation = translation.map { (current: $0.0, options: $0.1) }
        show()
    }

    func showTranscribing() {
        model.phase = .transcribing
        show()
    }

    func showError(_ message: String) {
        model.phase = .error(message)
        show()
    }

    func updateLevel(_ level: Float) {
        model.level = level
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func show() {
        let panel = ensurePanel()
        // 错误信息可能较长,面板随内容自适应
        if let hostView {
            let size = hostView.fittingSize
            panel.setContentSize(size)
        }
        place(panel)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
                            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                            backing: .buffered,
                            defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self

        let host = NSHostingView(rootView: RecordingBarView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        hostView = host

        self.panel = panel
        return panel
    }

    /// 摆放:优先用户上次拖到的位置;否则当前焦点窗口所在屏幕的底部中央
    private func place(_ panel: NSPanel) {
        programmaticMove = true
        defer { programmaticMove = false }

        let screen = currentScreen()
        if let saved = settings.savedPanelOrigin() {
            // 保存的是相对屏幕 visibleFrame 的比例位置,跨屏幕/分辨率仍有效
            let frame = screen.visibleFrame
            let origin = CGPoint(x: frame.minX + saved.x * frame.width,
                                 y: frame.minY + saved.y * frame.height)
            panel.setFrameOrigin(clamp(origin, size: panel.frame.size, in: frame))
        } else {
            let frame = screen.visibleFrame
            let origin = CGPoint(x: frame.midX - panel.frame.width / 2,
                                 y: frame.minY + 64)
            panel.setFrameOrigin(origin)
        }
    }

    /// 当前正在使用的窗口所在的屏幕(spec §4 多显示器要求)
    private func currentScreen() -> NSScreen {
        if let windowFrame = AXContextReader.focusedWindowFrame() {
            // AX 坐标系原点在左上,NSScreen 在左下;按窗口中心点匹配屏幕
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let center = CGPoint(x: windowFrame.midX, y: primaryHeight - windowFrame.midY)
            for screen in NSScreen.screens where screen.frame.contains(center) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func clamp(_ origin: CGPoint, size: CGSize, in frame: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, frame.minX), frame.maxX - size.width),
                y: min(max(origin.y, frame.minY), frame.maxY - size.height))
    }

    // MARK: - 拖动持久化

    func windowDidMove(_ notification: Notification) {
        guard !programmaticMove, let panel, panel.isVisible else { return }
        guard let screen = panel.screen else { return }
        let frame = screen.visibleFrame
        guard frame.width > 0, frame.height > 0 else { return }
        let relative = CGPoint(x: (panel.frame.minX - frame.minX) / frame.width,
                               y: (panel.frame.minY - frame.minY) / frame.height)
        settings.savePanelOrigin(relative)
    }
}

// MARK: - SwiftUI 视图

struct RecordingBarView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Group {
            switch model.phase {
            case .listening: listening
            case .transcribing:
                Text("正在转录…")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            case .error(let message): errorView(message)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: 200)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listening: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 8, height: 8)
            LevelMeter(level: model.level)
            Text("正在聆听")
                .font(.system(size: 13))
            if model.translation != nil {
                languageMenu
            }
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(model.translation?.options ?? [], id: \.self) { language in
                Button(language) {
                    model.translation?.current = language
                    model.onLanguageChange?(language)
                }
            }
        } label: {
            Text("\(model.translation?.current ?? "") ▾")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(message)
                .font(.system(size: 12))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340, alignment: .leading)
            Button("重试") { model.onRetry?() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("关闭") { model.onDismissError?() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

/// 简单的音量柱动画
struct LevelMeter: View {
    var level: Float
    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tint)
                    .frame(width: 3, height: height(for: index))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.1), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        // 中间的柱子对音量更敏感,形成 ▂▅▇▅▂ 的波形感
        let weights: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]
        let h = 4 + CGFloat(level * weights[index]) * 12
        return min(16, h)
    }
}
