import Foundation
import Combine

/// 个人术语表,只存本地(spec §9)。
/// JSON 持久化在 ~/Library/Application Support/OpenVoiceInput/glossary.json
final class GlossaryStore: ObservableObject {
    struct Term: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        /// 同一纠正出现多次逐渐提高可信度(spec §12)
        var confidence: Int = 1
        var addedAt = Date()
        /// "manual" / "learned" / "imported"
        var source: String = "manual"
    }

    static let shared = GlossaryStore()

    @Published private(set) var terms: [Term] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenVoiceInput", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("glossary.json")
    }()

    private init() {
        load()
    }

    // MARK: - 查询

    func contains(_ text: String) -> Bool {
        terms.contains { $0.text.caseInsensitiveCompare(text) == .orderedSame }
    }

    func search(_ query: String) -> [Term] {
        guard !query.isEmpty else { return terms }
        return terms.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    /// 转录 prompt 用的术语提示。按可信度排序,限制总长度(ASR prompt 不宜过长)。
    func promptHint(limit: Int = 60) -> String {
        terms.sorted { $0.confidence > $1.confidence }
            .prefix(limit)
            .map(\.text)
            .joined(separator: ", ")
    }

    // MARK: - 修改

    func add(_ text: String, source: String = "manual") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = terms.firstIndex(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            // 已存在:学习来源时提升可信度,并采用新的大小写形式
            terms[index].confidence += 1
            terms[index].text = trimmed
        } else {
            terms.append(Term(text: trimmed, source: source))
        }
        save()
    }

    func remove(_ term: Term) {
        terms.removeAll { $0.id == term.id }
        save()
    }

    func removeByText(_ text: String) {
        terms.removeAll { $0.text.caseInsensitiveCompare(text) == .orderedSame }
        save()
    }

    /// 批量导入:每行一个术语
    func importText(_ content: String) -> Int {
        var count = 0
        for line in content.split(whereSeparator: \.isNewline) {
            let term = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 60, !contains(term) else { continue }
            terms.append(Term(text: term, source: "imported"))
            count += 1
        }
        if count > 0 { save() }
        return count
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Term].self, from: data) else { return }
        terms = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(terms) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
