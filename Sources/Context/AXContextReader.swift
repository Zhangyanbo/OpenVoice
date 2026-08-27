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
    /// 页面/文档其他内容的有限采样(开头+结尾各一段,或窗口级兜底采样)
    var documentText: String?

    var isEmpty: Bool {
        appName == nil && windowTitle == nil && selectedText == nil
            && beforeCursor == nil && afterCursor == nil && documentText == nil
    }

    /// 人类可读摘要,用于"查看本次发送的上下文"(spec §18)
    var summary: String {
        var lines: [String] = []
        if let appName { lines.append("App：\(appName)") }
        if let windowTitle { lines.append("窗口标题：\(windowTitle)") }
        if let selectedText { lines.append("选中文字：\(selectedText)") }
        if let beforeCursor { lines.append("光标前：…\(beforeCursor)") }
        if let afterCursor { lines.append("光标后：\(afterCursor)…") }
        if let documentText { lines.append("页面/文档内容：\n\(documentText)") }
        return lines.isEmpty ? "（无）" : lines.joined(separator: "\n")
    }
}

/// 插入目标:录音开始时记住,网络请求期间用户切走也要插回原处(spec §14)。
struct InsertionTarget {
    let pid: pid_t
    let element: AXUIElement?
    let selectionRange: CFRange?
    let hadSelectedText: Bool
    /// AX 读不到选区、只能由“复制”菜单取得文字时，写回必须走粘贴，不能误写到光标处。
    let selectionCapturedByCopy: Bool
    /// 密码框或焦点元素不可用时禁止尝试复制降级。
    let allowsCopySelectionFallback: Bool

    init(pid: pid_t, element: AXUIElement?, selectionRange: CFRange?,
         hadSelectedText: Bool, selectionCapturedByCopy: Bool = false,
         allowsCopySelectionFallback: Bool = false) {
        self.pid = pid
        self.element = element
        self.selectionRange = selectionRange
        self.hadSelectedText = hadSelectedText
        self.selectionCapturedByCopy = selectionCapturedByCopy
        self.allowsCopySelectionFallback = allowsCopySelectionFallback
    }
}

/// AX 优先读取上下文；选区属性缺失时，可在录音开始前通过 AX“复制”菜单做一次受控降级。
/// 不截图、不 OCR、不申请屏幕录制，也不模拟 Cmd+C。
enum AXContextReader {
    private static let beforeLimit = 1200
    private static let afterLimit = 600
    private static let docLeadLimit = 800
    private static let docTailLimit = 300
    private static let windowWalkNodeLimit = 150
    private static let windowWalkCharLimit = 2000

    /// 录音入口使用。先同步读取 AX；只有选区缺失时才异步执行一次复制菜单降级。
    static func captureForRecording(
        settings: SettingsStore,
        completion: @escaping (DictationContext, InsertionTarget?) -> Void
    ) {
        let captured = capture(settings: settings)
        guard settings.readSelectedText else {
            NSLog("AXContextReader: selection fallback skipped (setting disabled)")
            completion(captured.0, captured.1)
            return
        }
        guard captured.0.selectedText == nil else {
            NSLog("AXContextReader: selection captured directly by AX")
            completion(captured.0, captured.1)
            return
        }
        guard let target = captured.1 else {
            NSLog("AXContextReader: selection fallback skipped (no frontmost app)")
            completion(captured.0, captured.1)
            return
        }
        guard target.allowsCopySelectionFallback else {
            NSLog("AXContextReader: selection fallback skipped (secure field)")
            completion(captured.0, captured.1)
            return
        }

        NSLog(
            "AXContextReader: invoking selection fallback (pid=%d, focusedElement=%@)",
            target.pid,
            target.element == nil ? "no" : "yes"
        )
        SelectedTextCopyFallback.capture(pid: target.pid) { text in
            guard let text, !text.isEmpty else {
                completion(captured.0, captured.1)
                return
            }
            var context = captured.0
            context.selectedText = String(text.prefix(2000))
            let copiedTarget = InsertionTarget(
                pid: target.pid,
                element: target.element,
                selectionRange: target.selectionRange,
                hadSelectedText: true,
                selectionCapturedByCopy: true,
                allowsCopySelectionFallback: false
            )
            completion(context, copiedTarget)
        }
    }

    /// 读取当前焦点处的 AX 上下文 + 插入目标。任何一步失败都静默降级。
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
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
        let focusedAny = focusedRef,
        CFGetTypeID(focusedAny) == AXUIElementGetTypeID() else {
            if settings.useAppContext { context.windowTitle = frontWindowTitle(pid: pid) }
            return (context, InsertionTarget(
                pid: pid,
                element: nil,
                selectionRange: nil,
                hadSelectedText: false,
                allowsCopySelectionFallback: true
            ))
        }
        let element = focusedAny as! AXUIElement

        // 密码框绝不读取，也不尝试复制菜单降级。
        if stringAttr(element, kAXSubroleAttribute) == "AXSecureTextField" {
            return (context, InsertionTarget(
                pid: pid, element: nil, selectionRange: nil, hadSelectedText: false
            ))
        }

        if settings.useAppContext {
            context.windowTitle = windowTitle(of: element) ?? frontWindowTitle(pid: pid)
        }

        let range = rangeAttr(element, kAXSelectedTextRangeAttribute)
        if settings.readSelectedText {
            context.selectedText = selectedText(on: element, range: range)
                .map { String($0.prefix(2000)) }
        }

        var hasFocusedValue = false
        if settings.readNearbyText, let range,
           let value = stringAttr(element, kAXValueAttribute), !value.isEmpty {
            hasFocusedValue = true
            let chars = Array(value)
            let loc = min(max(0, range.location), chars.count)
            let end = min(max(loc, range.location + range.length), chars.count)
            let beforeStart = max(0, loc - beforeLimit)
            let afterEnd = min(chars.count, end + afterLimit)
            let before = String(chars[beforeStart..<loc])
            let after = String(chars[end..<afterEnd])
            if !before.isEmpty { context.beforeCursor = before }
            if !after.isEmpty { context.afterCursor = after }
            context.documentText = documentSample(
                chars: chars, beforeStart: beforeStart, afterEnd: afterEnd
            )
        }

        if settings.readNearbyText, !hasFocusedValue, context.selectedText == nil,
           let win = focusedWindowElement(pid: pid) {
            context.documentText = windowTextSample(window: win)
        }

        return (context, InsertionTarget(
            pid: pid,
            element: element,
            selectionRange: range,
            hadSelectedText: context.selectedText != nil,
            allowsCopySelectionFallback: true
        ))
    }

    // MARK: - AX helpers

    static func stringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    static func rangeAttr(_ element: AXUIElement, _ attr: String) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let any = ref, CFGetTypeID(any) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(any as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func selectedSubstring(in value: String, range: CFRange) -> String? {
        let text = value as NSString
        guard range.location >= 0, range.length > 0,
              range.location <= text.length,
              range.length <= text.length - range.location else { return nil }
        return text.substring(with: NSRange(location: range.location, length: range.length))
    }

    private static func selectedText(on element: AXUIElement, range: CFRange?) -> String? {
        if let text = stringAttr(element, kAXSelectedTextAttribute), !text.isEmpty {
            return text
        }
        guard let range, range.length > 0 else { return nil }

        var axRange = range
        if let rangeValue = AXValueCreate(.cfRange, &axRange) {
            var ref: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &ref
            ) == .success,
            let text = ref as? String, !text.isEmpty {
                return text
            }
        }

        guard let value = stringAttr(element, kAXValueAttribute) else { return nil }
        return selectedSubstring(in: value, range: range)
    }

    private static func windowTitle(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &ref) == .success,
              let any = ref, CFGetTypeID(any) == AXUIElementGetTypeID() else { return nil }
        return stringAttr(any as! AXUIElement, kAXTitleAttribute)
    }

    private static func focusedWindowElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let any = ref, CFGetTypeID(any) == AXUIElementGetTypeID() else { return nil }
        return (any as! AXUIElement)
    }

    private static func frontWindowTitle(pid: pid_t) -> String? {
        focusedWindowElement(pid: pid).flatMap { stringAttr($0, kAXTitleAttribute) }
    }

    private static func documentSample(
        chars: [Character], beforeStart: Int, afterEnd: Int
    ) -> String? {
        var parts: [String] = []
        if beforeStart > 0 {
            parts.append(String(chars[0..<min(beforeStart, docLeadLimit)]))
        }
        if afterEnd < chars.count {
            let tailCount = min(chars.count - afterEnd, docTailLimit)
            parts.append(String(chars[(chars.count - tailCount)...]))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n…\n")
    }

    private static func windowTextSample(window: AXUIElement) -> String? {
        var seen = Set<String>()
        var collected: [String] = []
        var charCount = 0
        var nodeCount = 0
        var queue: [AXUIElement] = [window]
        while !queue.isEmpty, nodeCount < windowWalkNodeLimit,
              charCount < windowWalkCharLimit {
            let element = queue.removeFirst()
            nodeCount += 1
            if let value = stringAttr(element, kAXValueAttribute),
               !value.isEmpty, !seen.contains(value) {
                seen.insert(value)
                let piece = String(value.prefix(windowWalkCharLimit - charCount))
                if !piece.isEmpty {
                    collected.append(piece)
                    charCount += piece.count
                }
            }
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString, &ref
            ) == .success,
            let children = ref as? [AXUIElement], !children.isEmpty {
                queue.append(contentsOf: children.prefix(windowWalkNodeLimit - nodeCount))
            }
        }
        return collected.isEmpty ? nil : collected.joined(separator: "\n")
    }

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
