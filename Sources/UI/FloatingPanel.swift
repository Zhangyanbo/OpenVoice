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
    /// 最近若干个音量采样(0...1),驱动流动的波形
    @Published var levels: [Float] = Array(repeating: 0, count: 5)
    /// 非空表示翻译模式:(当前目标语言, 可选语言列表)
    @Published var translation: (current: String, options: [String])?

    func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: levels.count)
    }

    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDismissError: (() -> Void)?
    var onLanguageChange: ((String) -> Void)?
    /// SwiftUI 布局完成后回报胶囊实际尺寸,窗口据此调整大小
    var onSizeChange: ((CGSize) -> Void)?
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
        model.resetLevels()
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
        model.pushLevel(level)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    private func show() {
        let panel = ensurePanel()
        place(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
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

        // 尺寸以 SwiftUI 布局结果为准(布局是异步的,同步读 fittingSize 会拿到过时值)
        model.onSizeChange = { [weak self] size in
            self?.resizePanel(to: size)
        }

        self.panel = panel
        return panel
    }

    /// 保持水平中心与底边不动,按内容实际尺寸调整窗口
    private func resizePanel(to size: CGSize) {
        guard let panel else { return }
        let target = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard target.width > 1, target.height > 1,
              abs(panel.frame.width - target.width) > 0.5 || abs(panel.frame.height - target.height) > 0.5 else { return }
        let origin = CGPoint(x: panel.frame.midX - target.width / 2, y: panel.frame.minY)
        programmaticMove = true
        panel.setFrame(NSRect(origin: origin, size: target), display: true)
        programmaticMove = false
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
//
// 视觉语言:深色磨砂玻璃胶囊(类似系统听写浮层)。
// 尺寸保持紧凑,不随状态膨胀;现代感来自材质、微动效与克制的层次,
// 而不是体积和高饱和颜色。

struct RecordingBarView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Group {
            switch model.phase {
            case .listening: listening
            case .transcribing: transcribing
            case .error(let message): errorView(message)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .fill(Color.black.opacity(0.45))
            }
        }
        .overlay {
            // 上亮下暗的一像素描边,营造玻璃边缘
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        // 胶囊始终按理想尺寸布局(不被窗口现有尺寸压缩截断),
        // 布局后把实际尺寸回报给窗口去适配
        .fixedSize()
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PillSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(PillSizeKey.self) { size in
            model.onSizeChange?(size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.18), value: model.phaseKey)
    }

    private var listening: some View {
        HStack(spacing: 10) {
            PulsingDot()
            WaveformView(levels: model.levels)
            Text("正在聆听")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            if model.translation != nil {
                languageMenu
            }
        }
    }

    private var transcribing: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.8))
            Text("正在转录…")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
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
            HStack(spacing: 3) {
                Text(model.translation?.current ?? "")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange.opacity(0.9))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
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

extension PanelModel {
    /// phase 不是 Equatable,给动画一个可比较的 key
    var phaseKey: Int {
        switch phase {
        case .listening: return 0
        case .transcribing: return 1
        case .error: return 2
        }
    }
}

private struct PillSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// 呼吸的录音点
private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color(red: 1.0, green: 0.29, blue: 0.26))
            .frame(width: 7, height: 7)
            .shadow(color: Color(red: 1.0, green: 0.29, blue: 0.26).opacity(pulsing ? 0.7 : 0.2), radius: pulsing ? 5 : 2)
            .opacity(pulsing ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

/// 随音量流动的波形:最近 N 个采样从右向左滑过
struct WaveformView: View {
    var levels: [Float]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2.5, height: height(for: level))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: levels)
    }

    private func height(for level: Float) -> CGFloat {
        3 + CGFloat(min(1, level)) * 13
    }
}
