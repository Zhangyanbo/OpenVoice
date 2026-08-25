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
}

/// 只用 Accessibility API 读取上下文。每一步都可能失败,失败即静默降级(spec §7)。
/// 不截图、不 OCR、不申请屏幕录制。
enum AXContextReader {
    private static let beforeLimit = 1200
    private static let afterLimit = 600
    /// documentText 里附加的文档开头/结尾采样上限
    private static let docLeadLimit = 800
    private static let docTailLimit = 300
    /// 窗口级兜底采样:焦点控件没有文字时,在窗口树里收集可见文本
    private static let windowWalkNodeLimit = 150
    private static let windowWalkCharLimit = 2000

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

        // 焦点控件通常是整个文档/输入框,里面往往还有光标附近之外的可参考内容:
        // 取光标前后窗口 + 文档开头/结尾各一段有限采样(spec §5/§6)。
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
            context.documentText = documentSample(chars: chars, beforeStart: beforeStart, afterEnd: afterEnd)
        }

        // 焦点控件读不到文字(不是输入框/编辑器)时,退到窗口级采样:
        // 页面里往往还有静态文本、列表、代码等其他可参考内容。
        if settings.readNearbyText, !hasFocusedValue, context.selectedText == nil,
           let win = focusedWindowElement(pid: pid) {
            context.documentText = windowTextSample(window: win)
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

    /// 光标窗口之外的文档采样:开头 + 结尾各一段,避开已由光标前后文字覆盖的区间。
    /// 输出总长有上限;没有可附加的部分返回 nil。
    private static func documentSample(chars: [Character], beforeStart: Int, afterEnd: Int) -> String? {
        var parts: [String] = []
        if beforeStart > 0 {
            let leadCount = min(beforeStart, docLeadLimit)
            parts.append(String(chars[0..<leadCount]))
        }
        if afterEnd < chars.count {
            let tailCount = min(chars.count - afterEnd, docTailLimit)
            parts.append(String(chars[(chars.count - tailCount)...]))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n…\n")
    }

    /// 从窗口根开始的有界遍历:收集可见文本元素的值,去重,限制节点数与总字符数。
    /// 焦点控件读不到文字时的兜底,拿不到或没有可读内容返回 nil。
    private static func windowTextSample(window: AXUIElement) -> String? {
        var seen = Set<String>()
        var collected: [String] = []
        var charCount = 0
        var nodeCount = 0
        var queue: [AXUIElement] = [window]
        while !queue.isEmpty, nodeCount < windowWalkNodeLimit, charCount < windowWalkCharLimit {
            let el = queue.removeFirst()
            nodeCount += 1
            if let value = stringAttr(el, kAXValueAttribute), !value.isEmpty, !seen.contains(value) {
                seen.insert(value)
                let piece = String(value.prefix(windowWalkCharLimit - charCount))
                if !piece.isEmpty {
                    collected.append(piece)
                    charCount += piece.count
                }
            }
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
               let children = ref as? [AXUIElement], !children.isEmpty {
                let remaining = max(0, windowWalkNodeLimit - nodeCount)
                queue.append(contentsOf: children.prefix(remaining))
            }
        }
        guard !collected.isEmpty else { return nil }
        return collected.joined(separator: "\n")
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
