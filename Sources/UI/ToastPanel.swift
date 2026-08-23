import AppKit
import SwiftUI

/// 轻量提示条:如「已学习"MacroNet"  撤销」或「结果已复制到剪贴板」。
/// 自动消失,绝不弹模态窗口(spec §12)。
enum ToastPanel {
    private static var panel: NSPanel?
    private static var dismissWork: DispatchWorkItem?

    static func show(message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        dismissWork?.cancel()
        panel?.orderOut(nil)

        let view = ToastView(message: message, actionTitle: actionTitle) {
            action?()
            hide()
        }
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)

        let newPanel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                               styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                               backing: .buffered,
                               defer: true)
        newPanel.isFloatingPanel = true
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.contentView = host

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        newPanel.setFrameOrigin(CGPoint(x: frame.midX - host.fittingSize.width / 2,
                                        y: frame.minY + 120))
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            newPanel.animator().alphaValue = 1
        }
        panel = newPanel

        let work = DispatchWorkItem { hide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    static func hide() {
        dismissWork?.cancel()
        dismissWork = nil
        guard let current = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            current.animator().alphaValue = 0
        }, completionHandler: {
            current.orderOut(nil)
        })
    }
}

private struct ToastView: View {
    let message: String
    let actionTitle: String?
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
            if let actionTitle {
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.black.opacity(0.45))
            }
        }
        .overlay {
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        .padding(4)
    }
}
