import AppKit
import SelectedTextKit

/// AX 文本属性无法取得选区时，调用 SelectedTextKit 的“复制菜单”单一路径。
/// 明确不使用它的 `.auto` 或 `.shortcut`，因此不会模拟 Cmd+C。
enum SelectedTextCopyFallback {
    static func capture(pid: pid_t, completion: @escaping (String?) -> Void) {
        Task { @MainActor in
            guard Permissions.accessibilityGranted else {
                NSLog("SelectedTextCopyFallback: skipped (accessibility denied)")
                completion(nil)
                return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                NSLog("SelectedTextCopyFallback: skipped (frontmost app changed)")
                completion(nil)
                return
            }

            do {
                let text = try await SelectedTextManager.shared.getSelectedText(
                    strategy: .menuAction
                )
                guard let text, !text.isEmpty else {
                    NSLog("SelectedTextCopyFallback: menu action returned no text")
                    completion(nil)
                    return
                }
                NSLog("SelectedTextCopyFallback: menu action captured %d characters", text.count)
                completion(text)
            } catch {
                NSLog("SelectedTextCopyFallback: menu action failed: %@", error.localizedDescription)
                completion(nil)
            }
        }
    }
}
