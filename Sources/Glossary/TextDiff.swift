import Foundation

/// 词级文本 diff + 保守的术语学习规则(spec §11–12)。
enum TextDiff {
    struct Replacement: Equatable {
        let old: String
        let new: String
    }

    /// 找出 old → new 之间的词级替换。只有"看起来像词语纠正"的会被返回。
    static func wordReplacements(old: String, new: String) -> [Replacement] {
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        guard !oldTokens.isEmpty, !newTokens.isEmpty else { return [] }

        // LCS 对齐
        let lcs = lcsTable(oldTokens, newTokens)
        var i = oldTokens.count, j = newTokens.count
        var chunks: [(old: [String], new: [String])] = []
        var currentOld: [String] = []
        var currentNew: [String] = []

        func flush() {
            if !currentOld.isEmpty || !currentNew.isEmpty {
                chunks.append((currentOld.reversed(), currentNew.reversed()))
                currentOld = []
                currentNew = []
            }
        }

        while i > 0 || j > 0 {
            if i > 0, j > 0, oldTokens[i - 1] == newTokens[j - 1] {
                flush()
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || lcs[i][j - 1] >= lcs[i - 1][j] {
                currentNew.append(newTokens[j - 1])
                j -= 1
            } else {
                currentOld.append(oldTokens[i - 1])
                i -= 1
            }
        }
        flush()

        return chunks.compactMap { chunk in
            let oldText = chunk.old.joined(separator: " ")
            let newText = chunk.new.joined(separator: " ")
            guard looksLikeWordCorrection(old: oldText, new: newText,
                                          oldCount: chunk.old.count, newCount: chunk.new.count) else { return nil }
            return Replacement(old: oldText, new: newText)
        }
    }

    /// 保守规则:小范围、双方非空、非纯标点/大小写无关变化太大时不学
    static func looksLikeWordCorrection(old: String, new: String, oldCount: Int, newCount: Int) -> Bool {
        // 双方都要有内容(纯删除/纯插入不是"纠正")
        guard !old.isEmpty, !new.isEmpty else { return false }
        // 范围小:每侧 ≤ 3 个词,≤ 40 字符
        guard oldCount <= 3, newCount <= 3, old.count <= 40, new.count <= 40 else { return false }
        // 新词必须含字母或 CJK(纯标点、纯数字修改不学)
        guard new.contains(where: { $0.isLetter }) else { return false }

        // 归一化(去掉大小写、空格、标点)后必须"相似":
        // macro net → MacroNet 归一化后相等;epiplex city → Epiplexity 编辑距离小
        let a = normalize(old)
        let b = normalize(new)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let distance = editDistance(a, b)
        let maxLen = max(a.count, b.count)
        return distance <= max(2, maxLen * 2 / 5)
    }

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }

    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = a[i - 1] == b[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table
    }
}
