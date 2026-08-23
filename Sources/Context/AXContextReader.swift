import Foundation
import AppKit
import ApplicationServices

/// 一次语音输入开始时采集的最小上下文(spec §6)。任何字段都可能为空。
struct DictationContext {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var selectedText: String?
    var beforeCursor: String?
    var afterCursor: String?

    var isEmpty: Bool {
        appName == nil && windowTitle == nil && selectedText == nil
            && beforeCursor == nil && afterCursor == nil
    }

    /// 人类可读摘要,用于"查看本次发送的上下文"(spec §18)
    var summary: String {
        var lines: [String] = []
        if let appName { lines.append("App：\(appName)") }
        if let windowTitle { lines.append("窗口标题：\(windowTitle)") }
        if let selectedText { lines.append("选中文字：\(selectedText)") }
        if let beforeCursor { lines.append("光标前：…\(beforeCursor)") }
        if let afterCursor { lines.append("光标后：\(afterCursor)…") }
        return lines.isEmpty ? "（无）" : lines.joined(separator: "\n")
    }
}

/// 插入目标:录音开始时记住,网络请求期间用户切走也要插回原处(spec §14)。
struct InsertionTarget {
    let pid: pid_t
    let element: AXUIElement?
    let selectionRange: CFRange?
    let hadSelectedText: Bool
}

/// 只用 Accessibility API 读取上下文。每一步都可能失败,失败即静默降级(spec §7)。
/// 不截图、不 OCR、不申请屏幕录制。
enum AXContextReader {
    private static let beforeLimit = 400
    private static let afterLimit = 200

    /// 读取当前焦点处的上下文 + 插入目标。必须在开始录音的瞬间调用一次。
    static func capture(settings: SettingsStore) -> (DictationContext, InsertionTarget?) {
        var context = DictationContext()

        let frontApp = NSWorkspace.shared.frontmostApplication
        if settings.useAppContext {
            context.appName = frontApp?.localizedName
            context.bundleID = frontApp?.bundleIdentifier
        }

        guard Permissions.accessibilityGranted, let pid = frontApp?.processIdentifier else {
            return (context, nil)
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedAny = focusedRef, CFGetTypeID(focusedAny) == AXUIElementGetTypeID() else {
            if settings.useAppContext {
                context.windowTitle = frontWindowTitle(pid: pid)
            }
            return (context, InsertionTarget(pid: pid, element: nil, selectionRange: nil, hadSelectedText: false))
        }
        let element = focusedAny as! AXUIElement

        // 密码框绝不读取
        if stringAttr(element, kAXSubroleAttribute) == "AXSecureTextField" {
            return (context, InsertionTarget(pid: pid, element: nil, selectionRange: nil, hadSelectedText: false))
        }

        if settings.useAppContext {
            context.windowTitle = windowTitle(of: element) ?? frontWindowTitle(pid: pid)
        }

        var selectedText: String?
        if settings.readSelectedText {
            selectedText = stringAttr(element, kAXSelectedTextAttribute)
            if let s = selectedText, s.isEmpty { selectedText = nil }
            context.selectedText = selectedText.map { String($0.prefix(2000)) }
        }

        let range = rangeAttr(element, kAXSelectedTextRangeAttribute)

        if settings.readNearbyText, let range,
           let value = stringAttr(element, kAXValueAttribute), !value.isEmpty {
            let chars = Array(value)
            let loc = min(max(0, range.location), chars.count)
            let end = min(max(loc, range.location + range.length), chars.count)
            let beforeStart = max(0, loc - beforeLimit)
            let afterEnd = min(chars.count, end + afterLimit)
            let before = String(chars[beforeStart..<loc])
            let after = String(chars[end..<afterEnd])
            if !before.isEmpty { context.beforeCursor = before }
            if !after.isEmpty { context.afterCursor = after }
        }

        let target = InsertionTarget(pid: pid,
                                     element: element,
                                     selectionRange: range,
                                     hadSelectedText: context.selectedText != nil)
        return (context, target)
    }

    // MARK: - AX helpers

    static func stringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    static func rangeAttr(_ element: AXUIElement, _ attr: String) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let any = ref, CFGetTypeID(any) == AXValueGetTypeID() else { return nil }
        let axValue = any as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func windowTitle(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &ref) == .success,
              let any = ref, CFGetTypeID(any) == AXUIElementGetTypeID() else { return nil }
        return stringAttr(any as! AXUIElement, kAXTitleAttribute)
    }

    private static func frontWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let any = ref, CFGetTypeID(any) == AXUIElementGetTypeID() else { return nil }
        return stringAttr(any as! AXUIElement, kAXTitleAttribute)
    }

    /// 当前焦点窗口的屏幕位置,用于悬浮条跟随(拿不到返回 nil)
    static func focusedWindowFrame() -> CGRect? {
        guard Permissions.accessibilityGranted,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winAny = winRef, CFGetTypeID(winAny) == AXUIElementGetTypeID() else { return nil }
        let win = winAny as! AXUIElement

        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posAny = posRef, CFGetTypeID(posAny) == AXValueGetTypeID(),
              let sizeAny = sizeRef, CFGetTypeID(sizeAny) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posAny as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeAny as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }
}
