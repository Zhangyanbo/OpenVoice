import Foundation

/// 后处理模型通常返回 `{\"text\": \"...\"}`，但某些网关可能忽略
/// 结构化输出约束而返回裸文本。只有真正的裸文本可以降级接受；
/// 以 JSON 开头却无法完整解析的内容必然已截断，不得插入文档。
enum PostProcessingOutput {
    static func text(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = object["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !looksLikeStructuredOutput(trimmed) else { return nil }
        return trimmed
    }

    private static func looksLikeStructuredOutput(_ content: String) -> Bool {
        if content.first == "{" || content.first == "[" { return true }
        guard content.hasPrefix("```") else { return false }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return false }
        let body = lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.first == "{" || body.first == "["
    }
}
