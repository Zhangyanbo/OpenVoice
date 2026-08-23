import Foundation
import AppKit
import CoreGraphics

/// 全局快捷键监听。
///
/// Fn 是修饰键,普通热键 API(RegisterEventHotKey)注册不到,必须用 CGEventTap
/// 监听 flagsChanged(需要辅助功能权限)。
///
/// 触发规则(避免劫持 Fn+方向键 等系统组合):
/// - 修饰键按下期间若按过任何其他普通键 → 本次按键忽略;
/// - 在修饰键**抬起**时判定:
///   - 正在录音 → 停止;
///   - 未录音且左 Shift 按住(或按下期间按过左 Shift)→ 翻译模式;
///   - 否则 → 普通语音输入。
/// - 录音中按 Esc → 取消,且吞掉该事件不传给当前 App。
final class HotkeyManager {
    enum Trigger {
        case toggleDictation   // 主键:未录音开始普通输入 / 录音中停止
        case toggleTranslation // 主键+左Shift:开始翻译输入
        case cancel            // Esc(仅录音中)
    }

    /// 在主队列异步调用;是否吞掉事件由 tap 回调内的廉价状态判断决定
    var onTrigger: ((Trigger) -> Void)?
    /// 由 DictationController 维护;录音中才拦截 Esc
    var isRecordingProvider: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// tap 是否创建成功。没有辅助功能权限时创建会失败,
    /// 外部据此在权限恢复后重建(见 AppDelegate 的看门狗)
    var isActive: Bool { eventTap != nil }
    private let settings = SettingsStore.shared

    // 按键状态
    private var primaryDown = false
    private var otherKeyPressedDuringPrimary = false
    private var leftShiftDown = false
    private var shiftSeenDuringPrimary = false

    private static let leftShiftKeyCode: Int64 = 56
    private static let escKeyCode: Int64 = 53

    func start() {
        guard eventTap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("HotkeyManager: 无法创建事件 tap（缺少辅助功能权限？）")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    /// 权限授予后重启 tap
    func restart() {
        stop()
        start()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统在负载高时会禁用 tap,必须重新启用
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let recording = isRecordingProvider?() ?? false

        switch type {
        case .flagsChanged:
            handleFlagsChanged(keyCode: keyCode, flags: event.flags)
            return Unmanaged.passUnretained(event)

        case .keyDown:
            // 录音中 Esc → 取消并吞掉
            if recording, keyCode == Self.escKeyCode {
                fire(.cancel)
                return nil
            }
            // 非修饰键型的主/备用键(F13 等)→ 触发并吞掉
            if let trigger = fKeyTrigger(keyCode: keyCode) {
                fire(trigger)
                return nil
            }
            if primaryDown { otherKeyPressedDuringPrimary = true }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) {
        // 左 Shift 状态跟踪
        if keyCode == Self.leftShiftKeyCode {
            leftShiftDown = flags.contains(.maskShift)
            if primaryDown && leftShiftDown { shiftSeenDuringPrimary = true }
            return
        }

        let isPrimary = isModifierTriggerKey(keyCode, settings.primaryKey)
            || isModifierTriggerKey(keyCode, settings.altKey)
        guard isPrimary else {
            // 其他修饰键(Cmd/Opt/Ctrl)按下也视为"组合键",不触发
            if primaryDown, isModifierPressed(keyCode: keyCode, flags: flags) {
                otherKeyPressedDuringPrimary = true
            }
            return
        }

        let down = modifierIsDown(keyCode: keyCode, flags: flags)
        if down && !primaryDown {
            primaryDown = true
            otherKeyPressedDuringPrimary = false
            shiftSeenDuringPrimary = leftShiftDown
        } else if !down && primaryDown {
            primaryDown = false
            guard !otherKeyPressedDuringPrimary else { return }
            let recording = isRecordingProvider?() ?? false
            if recording {
                fire(.toggleDictation) // 录音中任何主键抬起都是"停止"
            } else if shiftSeenDuringPrimary || leftShiftDown {
                fire(.toggleTranslation)
            } else {
                fire(.toggleDictation)
            }
        }
    }

    private func isModifierTriggerKey(_ keyCode: Int64, _ key: SettingsStore.TriggerKey) -> Bool {
        key.isModifier && key.keyCode == keyCode
    }

    private func fKeyTrigger(keyCode: Int64) -> Trigger? {
        for key in [settings.primaryKey, settings.altKey] where !key.isModifier {
            if key.keyCode == keyCode {
                return leftShiftDown && !(isRecordingProvider?() ?? false) ? .toggleTranslation : .toggleDictation
            }
        }
        return nil
    }

    /// 判断某个修饰键 keyCode 当前是按下还是抬起
    private func modifierIsDown(keyCode: Int64, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 63: return flags.contains(.maskSecondaryFn)
        case 54, 55: return flags.contains(.maskCommand)
        case 58, 61: return flags.contains(.maskAlternate)
        case 56, 60: return flags.contains(.maskShift)
        case 59, 62: return flags.contains(.maskControl)
        default: return false
        }
    }

    private func isModifierPressed(keyCode: Int64, flags: CGEventFlags) -> Bool {
        modifierIsDown(keyCode: keyCode, flags: flags)
    }

    private func fire(_ trigger: Trigger) {
        // 事件 tap 回调必须立即返回,否则会卡住全系统键盘输入直至被系统禁用;
        // 实际工作(弹窗、AX 读取、启动录音)一律异步派发到主队列
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger?(trigger)
        }
    }
}
