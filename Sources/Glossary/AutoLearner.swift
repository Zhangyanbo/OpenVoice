import Foundation
import AppKit
import ApplicationServices

/// 插入文字后短时间观察同一控件,从用户的即时修改中学习术语(spec §10–12)。
///
/// 不做全局键盘记录。目标 App 不暴露 AXValue 时本轮学习直接失效,
/// 不采用任何替代方案 —— 能读取就增强,不能读取就跳过。
final class AutoLearner {
    /// 学习成功回调:(术语, 撤销闭包)
    var onLearned: ((String, @escaping () -> Void) -> Void)?

    private let glossary = GlossaryStore.shared
    private let settings = SettingsStore.shared

    private struct Observation {
        let element: AXUIElement
        let snapshotValue: String
        let insertedText: String
        let insertedLocation: Int
        let startedAt: Date
    }

    private var current: Observation?
    private var pendingTimers: [Timer] = []

    /// 每次成功插入后调用。element 为 nil(走了剪贴板且拿不到控件)时不观察。
    func beginObservation(element: AXUIElement?, insertedText: String) {
        cancelObservation()
        guard settings.autoLearn, let element else { return }
        // 修改前的快照必须能读到,否则这一轮直接失效
        guard let value = AXContextReader.stringAttr(element, kAXValueAttribute), !value.isEmpty else { return }
        guard let range = insertedRange(in: value, inserted: insertedText) else { return }

        current = Observation(element: element,
                              snapshotValue: value,
                              insertedText: insertedText,
                              insertedLocation: range.location,
                              startedAt: Date())

        // 语音输入后的较短时间内检查若干次
        for delay in [4.0, 10.0, 25.0] {
            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.check(isFinal: delay >= 25.0)
            }
            pendingTimers.append(timer)
        }
    }

    func cancelObservation() {
        pendingTimers.forEach { $0.invalidate() }
        pendingTimers = []
        current = nil
    }

    private func check(isFinal: Bool) {
        guard let obs = current else { return }
        guard let newValue = AXContextReader.stringAttr(obs.element, kAXValueAttribute) else {
            cancelObservation()
            return
        }
        guard newValue != obs.snapshotValue else {
            if isFinal { cancelObservation() }
            return
        }

        defer { cancelObservation() }

        // 定位变化区域:公共前缀/后缀之外的中间段
        let (oldMid, newMid, changeLocation) = Self.changedRegion(old: obs.snapshotValue, new: newValue)

        // 修改必须与刚插入的文字重合(spec §12)
        let insertedEnd = obs.insertedLocation + obs.insertedText.count
        guard changeLocation >= max(0, obs.insertedLocation - 2),
              changeLocation <= insertedEnd + 2 else { return }

        // 大段重写不学:变化区域不能明显超过插入内容本身
        guard oldMid.count <= obs.insertedText.count + 20,
              newMid.count <= obs.insertedText.count + 20 else { return }

        for replacement in TextDiff.wordReplacements(old: oldMid, new: newMid) {
            learn(replacement.new)
        }
    }

    private func learn(_ term: String) {
        let existed = glossary.contains(term)
        glossary.add(term, source: "learned")
        // 已有术语只提升可信度,不重复提示
        guard !existed else { return }
        let glossary = self.glossary
        DispatchQueue.main.async { [weak self] in
            self?.onLearned?(term) {
                glossary.removeByText(term)
            }
        }
    }

    /// 在整体文本中找到插入内容的位置(优先精确匹配)
    private func insertedRange(in value: String, inserted: String) -> (location: Int, length: Int)? {
        guard !inserted.isEmpty, let range = value.range(of: inserted, options: .backwards) else { return nil }
        return (value.distance(from: value.startIndex, to: range.lowerBound), inserted.count)
    }

    /// 公共前缀/后缀之外的中间变化段
    static func changedRegion(old: String, new: String) -> (oldMid: String, newMid: String, location: Int) {
        let oldChars = Array(old)
        let newChars = Array(new)
        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count, oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }
        // 变化段向两侧扩到词边界,保证拿到完整的词
        var start = prefix
        while start > 0, !oldChars[start - 1].isWhitespace || (start <= newChars.count && start > 0 && !newChars[start - 1].isWhitespace) {
            if oldChars[start - 1].isWhitespace { break }
            start -= 1
        }
        var oldEnd = oldChars.count - suffix
        while oldEnd < oldChars.count, !oldChars[oldEnd].isWhitespace { oldEnd += 1 }
        var newEnd = newChars.count - suffix
        while newEnd < newChars.count, !newChars[newEnd].isWhitespace { newEnd += 1 }

        let oldMid = String(oldChars[min(start, oldChars.count)..<max(min(start, oldChars.count), oldEnd)])
        let newMid = String(newChars[min(start, newChars.count)..<max(min(start, newChars.count), newEnd)])
        return (oldMid, newMid, start)
    }
}
