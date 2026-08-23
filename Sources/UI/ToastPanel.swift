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
        newPanel.orderFrontRegardless()
        panel = newPanel

        let work = DispatchWorkItem { hide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    static func hide() {
        dismissWork?.cancel()
        dismissWork = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ToastView: View {
    let message: String
    let actionTitle: String?
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message).font(.system(size: 12))
            if let actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
        .padding(4)
    }
}
