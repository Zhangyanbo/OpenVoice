import AppKit
import Carbon.HIToolbox

/// 保存并原样恢复系统剪贴板。使用底层 Pasteboard API，避免恢复文件 URL 时同步访问磁盘。
enum PasteboardPreserver {
    typealias Snapshot = [[String: Data]]

    static func snapshot(_ pasteboard: NSPasteboard = .general) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type.rawValue] = data
                }
            }
            return entry
        }
    }

    @discardableResult
    static func restore(_ items: Snapshot) -> Bool {
        var rawPasteboard: Pasteboard?
        guard PasteboardCreate(kPasteboardClipboard as CFString, &rawPasteboard) == noErr,
              let rawPasteboard,
              PasteboardClear(rawPasteboard) == noErr else {
            return false
        }
        guard !items.isEmpty else { return true }

        for (index, entry) in items.enumerated() {
            guard let itemID = UnsafeMutableRawPointer(bitPattern: index + 1) else { continue }
            for (type, data) in entry {
                guard PasteboardPutItemFlavor(
                    rawPasteboard,
                    itemID,
                    type as CFString,
                    data as CFData,
                    PasteboardFlavorFlags(rawValue: 0)
                ) == noErr else {
                    return false
                }
            }
        }
        return true
    }
}
