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
        trace = []
        log("目标：pid=\(target?.pid.description ?? "无") 控件=\(target?.element != nil ? "有" : "无")")
        // 先把焦点还给原来的 App(网络请求期间用户可能切走了)
        reactivateIfNeeded(target: target) {
            if target?.requiresPasteInsertion == true {
                // AX 无法描述原选区，直接 AX 写入只会落到光标处；保留原选区并用粘贴替换。
                log("选区由复制菜单取得，直接走粘贴替换")
                pasteInsert(text, target: target, completion: completion)
                return
            }
            if let target, let element = target.element, axInsert(text, target: target, element: element) {
                completion(.inserted(method: .accessibility))
                return
            }
            pasteInsert(text, target: target, completion: completion)
        }
    }

    /// 插入过程的决策轨迹，仅写入本机统一日志。
    private static var trace: [String] = []

    private static func log(_ message: String) {
        trace.append(message)
        NSLog("TextInserter: \(message)")
    }

    // MARK: - 路径 1:Accessibility 直接写入

    private static func axInsert(_ text: String, target: InsertionTarget, element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let settableErr = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settableErr == .success, settable.boolValue else {
            log("AX 路径不可用（settable=\(settable.boolValue), err=\(settableErr.rawValue)），改走粘贴")
            return false
        }

        // 恢复录音时的选区/光标位置;失败不阻塞(用户可能没动过光标)
        if let range = target.selectionRange {
            var r = range
            if let axRange = AXValueCreate(.cfRange, &r) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
            }
        }

        let setErr = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard setErr == .success else {
            log("AX 写入失败（err=\(setErr.rawValue)），改走粘贴")
            return false
        }

        // 某些 App 声称可写、返回 success,但实际静默忽略写入。
        // 能读回 value 时校验一下;读不回则只能信任 success
        if let value = AXContextReader.stringAttr(element, kAXValueAttribute) {
            let sample = String(text.prefix(80))
            guard value.contains(sample) else {
                log("AX 返回成功但控件内容里找不到插入文本（静默失败），改走粘贴")
                return false
            }
        }
        log("AX 直接写入成功")
        return true
    }

    // MARK: - 路径 2:剪贴板 + Cmd+V

    private static func pasteInsert(_ text: String, target: InsertionTarget?, completion: @escaping (Result) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard Permissions.accessibilityGranted, sendCmdV() else {
            // 无法模拟粘贴:文字留在剪贴板,不恢复旧内容(spec §19)
            log("无法模拟 Cmd+V（权限或事件创建失败），文字留在剪贴板")
            completion(.copiedToClipboardOnly)
            return
        }
        log("已模拟 Cmd+V 粘贴")

        // 粘贴在目标 App 里是异步完成的,过早恢复剪贴板会粘到旧内容
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            restore(items: saved)
            completion(.inserted(method: .paste))
        }
    }

    private static func sendCmdV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // 统一投递到 HID tap:目标 App 已被激活,这比 postToPid 兼容性好得多
        // (Chrome/Electron 等对 postToPid 的合成按键经常不响应)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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

    private static func restore(items: [[String: Data]]) {
        // 底层 Pasteboard API 原样恢复 flavor，避免重新解析文件 URL 时同步访问磁盘。
        var rawPasteboard: Pasteboard?
        guard PasteboardCreate(kPasteboardClipboard as CFString, &rawPasteboard) == noErr,
              let rawPasteboard else {
            log("剪贴板恢复失败（无法打开系统剪贴板）")
            return
        }
        guard PasteboardClear(rawPasteboard) == noErr else {
            log("剪贴板恢复失败（无法清空临时文本）")
            return
        }
        guard !items.isEmpty else { return }

        for (index, entry) in items.enumerated() {
            guard let itemID = UnsafeMutableRawPointer(bitPattern: index + 1) else { continue }
            for (type, data) in entry {
                let status = PasteboardPutItemFlavor(rawPasteboard, itemID,
                                                     type as CFString, data as CFData,
                                                     PasteboardFlavorFlags(rawValue: 0))
                if status != noErr {
                    log("剪贴板类型恢复失败（type=\(type), err=\(status)）")
                }
            }
        }
    }

}
