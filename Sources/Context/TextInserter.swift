import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 把最终文字插回录音开始时记录的位置。
/// 优先 AX 直接写入;不支持则降级为 剪贴板 + 模拟 Cmd+V(spec §14)。
enum TextInserter {
    enum Result {
        case inserted(method: InsertMethod)
        /// 两条路都失败,文字已留在剪贴板
        case copiedToClipboardOnly
    }

    enum InsertMethod { case accessibility, paste }

    /// 插入成功时返回所用方法;完全失败时把文字留在剪贴板并返回 .copiedToClipboardOnly。
    /// 必须在主线程调用。
    static func insert(_ text: String, target: InsertionTarget?, completion: @escaping (Result) -> Void) {
        // 先把焦点还给原来的 App(网络请求期间用户可能切走了)
        reactivateIfNeeded(target: target) {
            if let target, let element = target.element, axInsert(text, target: target, element: element) {
                completion(.inserted(method: .accessibility))
                return
            }
            pasteInsert(text, target: target, completion: completion)
        }
    }

    // MARK: - 路径 1:Accessibility 直接写入

    private static func axInsert(_ text: String, target: InsertionTarget, element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }

        // 恢复录音时的选区/光标位置;失败不阻塞(用户可能没动过光标)
        if let range = target.selectionRange {
            var r = range
            if let axRange = AXValueCreate(.cfRange, &r) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
            }
        }

        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    // MARK: - 路径 2:剪贴板 + Cmd+V

    private static func pasteInsert(_ text: String, target: InsertionTarget?, completion: @escaping (Result) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard Permissions.accessibilityGranted, sendCmdV(pid: target?.pid) else {
            // 无法模拟粘贴:文字留在剪贴板,不恢复旧内容(spec §19)
            completion(.copiedToClipboardOnly)
            return
        }

        // 粘贴在目标 App 里是异步完成的,立即恢复剪贴板会粘到旧内容
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            restore(pasteboard, items: saved)
            completion(.inserted(method: .paste))
        }
    }

    private static func sendCmdV(pid: pid_t?) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        if let pid {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func reactivateIfNeeded(target: InsertionTarget?, then run: @escaping () -> Void) {
        guard let pid = target?.pid,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isActive else {
            run()
            return
        }
        app.activate()
        // 给窗口切换留一点时间
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: run)
    }

    // MARK: - 剪贴板快照/恢复

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type.rawValue] = data }
            }
            return entry
        }
    }

    private static func restore(_ pasteboard: NSPasteboard, items: [[String: Data]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
