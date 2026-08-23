import Foundation
import AVFoundation
import AppKit
import ApplicationServices

enum Permissions {
    // MARK: - 麦克风

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - 辅助功能

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统的辅助功能授权提示(把本 App 加入列表)
    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - 错误弹窗(spec §19)

    static func showMicrophoneAlert() {
        let alert = NSAlert()
        alert.messageText = tr("需要麦克风权限才能进行语音输入。")
        alert.addButton(withTitle: tr("打开系统设置"))
        alert.addButton(withTitle: tr("取消"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }

    static func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = tr("需要辅助功能权限才能在其他 App 中读取和输入文字。")
        alert.addButton(withTitle: tr("打开系统设置"))
        alert.addButton(withTitle: tr("取消"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }
}
