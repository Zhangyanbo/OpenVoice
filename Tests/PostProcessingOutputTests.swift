import XCTest
@testable import OpenVoice

final class PostProcessingOutputTests: XCTestCase {
    func testOutputTokenCeilingUsesCompletePromptAndDoublesEstimate() {
        let selectedTextPrompt = String(repeating: "文", count: 1_000)

        XCTAssertEqual(
            OpenAIClient.outputTokenCeiling(system: "", user: selectedTextPrompt),
            2_000
        )
    }

    func testOutputTokenCeilingKeepsMinimumForShortPrompt() {
        XCTAssertEqual(OpenAIClient.outputTokenCeiling(system: "short", user: "prompt"), 512)
    }

    func testStructuredOutputExtractsText() {
        XCTAssertEqual(PostProcessingOutput.text(from: #"{"text":"hello"}"#), "hello")
    }

    func testPlainTextFallbackRemainsAvailable() {
        XCTAssertEqual(PostProcessingOutput.text(from: "hello"), "hello")
    }

    func testTruncatedJSONObjectIsRejected() {
        XCTAssertNil(PostProcessingOutput.text(from: #"{"text":"unfinished"#))
    }

    func testTruncatedJSONCodeFenceIsRejected() {
        XCTAssertNil(PostProcessingOutput.text(from: "```json\n{\"text\":\"unfinished"))
    }

    func testAppleInstructionsRemoveSelectedTextJSONRequirement() {
        let system = "- 以 JSON 输出，处理后的完整文本放在 text 字段中；text 里只有用于替换选区的正文，不含任何解释或前后缀。"
        let result = AppleIntelligenceClient.nativeInstructions(from: system)

        XCTAssertFalse(result.contains("以 JSON 输出"))
        XCTAssertTrue(result.contains("将处理后的完整正文直接填入结构化输出的 text 属性"))
    }
}
