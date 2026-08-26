import AppKit
import SwiftUI
import Combine

/// 悬浮条状态模型
final class PanelModel: ObservableObject {
    enum Phase {
        case listening
        case transcribing
        case processing
        case error(String)
        case update(String)
    }

    @Published var phase: Phase = .listening
    /// 最近若干个音量采样(0...1),驱动流动的波形
    @Published var levels: [Float] = Array(repeating: 0, count: 5)
    /// 非空表示接近最长录音时长:显示剩余秒数倒计时
    @Published var countdownSeconds: Int?
    /// 录音阶段连续进度（0...1），由核心状态机的 10 分钟上限计算。
    @Published var recordingProgress: Double = 0
    /// 处理阶段唯一的真实进度值；界面不再从另一条时间轴推算显示值。
    @Published var processingProgress: Double = 0
    @Published var fallbackFlash = false
    @Published var processingComplete = false
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
    var onInstallUpdate: (() -> Void)?
    var onDismissUpdate: (() -> Void)?
    /// SwiftUI 布局完成后回报胶囊实际尺寸,窗口据此调整大小
    var onSizeChange: ((CGSize) -> Void)?
}

/// 悬浮条窗口控制器(spec §4):
/// - .nonactivatingPanel,不抢当前 App 的键盘焦点;
/// - 浮在普通窗口之上,跟随当前使用的窗口所在屏幕;
/// - 可拖动,位置持久化;用完自动消失。
final class FloatingPanelController: NSObject, NSWindowDelegate {
    static let shared = FloatingPanelController()

    struct FallbackTiming {
        let preFlash: TimeInterval
        let retreat: TimeInterval
        let hold: TimeInterval
    }

    private var panel: NSPanel?
    private var hostView: NSHostingView<RecordingBarView>?
    private let model = PanelModel()
    private let settings = SettingsStore.shared
    /// 拖动持久化与程序化摆放会同时触发 windowDidMove,区分之
    private var programmaticMove = false
    private var completionHideWorkItem: DispatchWorkItem?
    private var activeCapability: ModelCapability?
    private var activeRequestTimeout: TimeInterval = 30
    private var progressTimer: Timer?
    private let progressTickInterval: TimeInterval = 1.0 / 20.0
    private let progressSnapDuration: TimeInterval = 0.24
    private let fallbackPreFlashDuration: TimeInterval = 0.12
    private let fallbackHoldDuration: TimeInterval = 0.12

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
    var onInstallUpdate: (() -> Void)? {
        get { model.onInstallUpdate }
        set { model.onInstallUpdate = newValue }
    }
    var onDismissUpdate: (() -> Void)? {
        get { model.onDismissUpdate }
        set { model.onDismissUpdate = newValue }
    }

    func showListening(translation: (String, [String])?) {
        cancelCompletionHide()
        stopProgressDriver()
        model.phase = .listening
        model.resetLevels()
        model.countdownSeconds = nil
        model.recordingProgress = 0
        model.processingProgress = 0
        model.fallbackFlash = false
        model.processingComplete = false
        activeCapability = nil
        model.translation = translation.map { (current: $0.0, options: $0.1) }
        show()
    }

    func updateCountdown(_ seconds: Int) {
        model.countdownSeconds = seconds
    }

    func updateRecordingProgress(_ progress: Double) {
        model.recordingProgress = min(1, max(0, progress))
    }

    func showTranscribing(timeoutSeconds: Int? = nil) {
        cancelCompletionHide()
        activeRequestTimeout = TimeInterval(timeoutSeconds ?? settings.modelRequestTimeoutSeconds)
        model.phase = .transcribing
        model.processingProgress = 0
        model.fallbackFlash = false
        model.processingComplete = false
        activeCapability = .transcription
        startProgressDriver(for: .transcription)
        show()
    }

    /// 转录成功时停止计时，并从屏幕当前的真实值快速补到 50%。
    func showTranscriptionComplete() -> TimeInterval {
        guard activeCapability == .transcription else { return 0 }
        stopProgressDriver()
        withAnimation(.easeOut(duration: progressSnapDuration)) {
            model.processingProgress = 0.5
        }
        return progressSnapDuration
    }

    func showPostProcessing(timeoutSeconds: Int? = nil) {
        activeRequestTimeout = TimeInterval(timeoutSeconds ?? settings.modelRequestTimeoutSeconds)
        activeCapability = .language
        model.phase = .processing
        model.processingProgress = 0.5
        model.fallbackFlash = false
        model.processingComplete = false
        startProgressDriver(for: .language)
        show()
    }

    /// fallback 分成明确的三步。路由器会等待三步完成，再发起下一个模型请求。
    func beginModelFallback(for capability: ModelCapability) -> FallbackTiming? {
        guard activeCapability == capability else { return nil }
        stopProgressDriver()
        if capability == .language { model.phase = .processing }
        withAnimation(.easeOut(duration: 0.08)) {
            model.fallbackFlash = true
        }
        return FallbackTiming(preFlash: fallbackPreFlashDuration,
                              retreat: progressSnapDuration,
                              hold: fallbackHoldDuration)
    }

    func retreatModelFallback(for capability: ModelCapability) {
        guard activeCapability == capability else { return }
        let stageStart = capability == .transcription ? 0.0 : 0.5
        withAnimation(.easeOut(duration: progressSnapDuration)) {
            model.processingProgress = stageStart
        }
    }

    /// 回退已经真正到达阶段起点后，恢复颜色并从起点开始下一轮。
    func resumeAfterModelFallback(for capability: ModelCapability) {
        guard activeCapability == capability else { return }
        withAnimation(.easeOut(duration: 0.1)) {
            model.fallbackFlash = false
        }
        startProgressDriver(for: capability)
    }

    /// 让 100% 填充有足够时间完成原生动画，然后再淡出；文字插入无需等待。
    func showProcessingComplete() {
        stopProgressDriver()
        activeCapability = nil
        model.phase = .processing
        model.fallbackFlash = false
        withAnimation(.easeOut(duration: progressSnapDuration)) {
            model.processingProgress = 1
        }
        model.processingComplete = true
        completionHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        completionHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: work)
    }

    func showError(_ message: String) {
        cancelCompletionHide()
        stopProgressDriver()
        model.phase = .error(message)
        model.processingProgress = 0
        model.fallbackFlash = false
        model.processingComplete = false
        activeCapability = nil
        show()
    }

    func showUpdate(version: String) {
        cancelCompletionHide()
        stopProgressDriver()
        model.phase = .update(version)
        model.processingProgress = 0
        model.fallbackFlash = false
        model.processingComplete = false
        model.countdownSeconds = nil
        model.translation = nil
        activeCapability = nil
        show()
    }

    func updateLevel(_ level: Float) {
        model.pushLevel(level)
    }

    func hide() {
        cancelCompletionHide()
        stopProgressDriver()
        activeCapability = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    private func cancelCompletionHide() {
        completionHideWorkItem?.cancel()
        completionHideWorkItem = nil
    }

    /// 每个模型尝试都从阶段起点重新计时。前半段在较短时间内走完，
    /// 后半段使用该模型完整 timeout 的剩余时间缓慢推进。
    private func startProgressDriver(for capability: ModelCapability) {
        stopProgressDriver()
        let stageStart = capability == .transcription ? 0.0 : 0.5
        let stageEnd = capability == .transcription ? 0.5 : 1.0
        let timeout = max(0.2, activeRequestTimeout)
        let fastDuration = min(3.0, max(0.6, timeout * 0.1))
        let startedAt = Date()

        model.processingProgress = stageStart
        let timer = Timer(timeInterval: progressTickInterval, repeats: true) { [weak self] timer in
            guard let self, self.activeCapability == capability else {
                timer.invalidate()
                return
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            let stageFraction: Double
            if elapsed <= fastDuration {
                stageFraction = 0.5 * min(1, elapsed / fastDuration)
            } else {
                let slowDuration = max(0.001, timeout - fastDuration)
                stageFraction = 0.5 + 0.5 * min(1, (elapsed - fastDuration) / slowDuration)
            }
            let progress = stageStart + (stageEnd - stageStart) * stageFraction
            withAnimation(.linear(duration: self.progressTickInterval)) {
                self.model.processingProgress = progress
            }
            if elapsed >= timeout { timer.invalidate() }
        }
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopProgressDriver() {
        progressTimer?.invalidate()
        progressTimer = nil
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
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var updater = UpdateManager.shared

    var body: some View {
        Group {
            if model.usesStableWidth {
                phaseContent
                    .frame(width: 104, alignment: .center)
            } else {
                phaseContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .fill(pillBaseColor)
                GeometryReader { proxy in
                    progressLayer(size: proxy.size)
                }
                .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
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
        .animation(.linear(duration: 0.5), value: model.recordingProgress)
        .animation(.easeInOut(duration: 0.3), value: model.isRecordingWarning)
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .listening: listening
        case .transcribing: transcribing
        case .processing: processing
        case .error(let message): errorView(message)
        case .update(let version): updateView(version)
        }
    }

    @ViewBuilder private func progressLayer(size: CGSize) -> some View {
        switch model.phase {
        case .listening:
            Rectangle()
                .fill(recordingProgressColor)
                .frame(width: size.width * model.recordingProgress, height: size.height)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .transcribing, .processing:
            Rectangle()
                .fill(processingProgressColor)
                .frame(width: size.width * model.processingProgress, height: size.height)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error, .update:
            EmptyView()
        }
    }

    private var listening: some View {
        HStack(spacing: 10) {
            PulsingDot()
            WaveformView(levels: model.levels)
            if let seconds = model.countdownSeconds {
                // 接近最长录音时长:文案变为倒计时，胶囊整体已进入橙红警示态。
                Text(tr("剩余 %d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
            } else {
                Text(tr("正在聆听"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            if model.translation != nil {
                languageMenu
            }
        }
    }

    private var transcribing: some View {
        processingStatus(label: tr("正在转录…"), complete: false)
    }

    private var processing: some View {
        let complete = model.processingComplete
        return processingStatus(label: complete ? tr("处理完成") : tr("正在处理…"),
                                complete: complete)
    }

    private func processingStatus(label: String, complete: Bool) -> some View {
        HStack(spacing: 9) {
            if complete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.8))
            }
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var pillBaseColor: Color {
        if model.isUpdate { return Color(red: 0.08, green: 0.36, blue: 0.86).opacity(0.88) }
        if model.isRecordingWarning {
            return Color(red: 0.72, green: 0.17, blue: 0.08).opacity(0.88)
        }
        return Color.black.opacity(0.45)
    }

    private var recordingProgressColor: Color {
        if model.isRecordingWarning {
            return Color(red: 1.0, green: 0.38, blue: 0.13).opacity(0.30)
        }
        // 前九分钟只用很弱的明度差，让胶囊仍接近原来的深灰色。
        return Color.white.opacity(0.065)
    }

    private var processingProgressColor: Color {
        if model.fallbackFlash {
            return Color(red: 0.96, green: 0.18, blue: 0.16).opacity(0.42)
        }
        return Color(red: 0.42, green: 0.58, blue: 0.76).opacity(0.22)
    }

    private var languageMenu: some View {
        Menu {
            ForEach(model.translation?.options ?? [], id: \.self) { language in
                Button(L10n.languageName(language)) {
                    model.translation?.current = language
                    model.onLanguageChange?(language)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(model.translation.map { L10n.languageName($0.current) } ?? "")
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
            Button(tr("重试")) { model.onRetry?() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(tr("关闭")) { model.onDismissError?() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func updateView(_ version: String) -> some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("OpenVoice %@ 可以更新", version))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                if case .failed(let message) = updater.phase {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .frame(maxWidth: 260, alignment: .leading)
                }
            }
            switch updater.phase {
            case .downloading:
                ProgressView().controlSize(.small).tint(.white)
                Text(tr("正在下载…"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            case .installing:
                ProgressView().controlSize(.small).tint(.white)
                Text(tr("正在安装…"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            default:
                Button(tr("升级")) { model.onInstallUpdate?() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(Color(red: 0.08, green: 0.32, blue: 0.76))
                    .controlSize(.small)
                Button { model.onDismissUpdate?() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension PanelModel {
    /// phase 不是 Equatable,给动画一个可比较的 key
    var phaseKey: Int {
        switch phase {
        case .listening: return 0
        case .transcribing: return 1
        case .processing: return 2
        case .error: return 3
        case .update: return 4
        }
    }

    var isUpdate: Bool {
        if case .update = phase { return true }
        return false
    }

    var isRecordingWarning: Bool {
        if case .listening = phase { return recordingProgress >= 0.9 }
        return false
    }

    var isProcessingPhase: Bool {
        switch phase {
        case .transcribing, .processing: return true
        default: return false
        }
    }

    var usesStableWidth: Bool {
        switch phase {
        case .transcribing, .processing: return true
        case .listening, .error, .update: return false
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
    private static let dotColor = Color(red: 0.24, green: 0.84, blue: 0.42)

    var body: some View {
        Circle()
            .fill(Self.dotColor)
            .frame(width: 7, height: 7)
            .shadow(color: Self.dotColor.opacity(pulsing ? 0.7 : 0.2), radius: pulsing ? 5 : 2)
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
