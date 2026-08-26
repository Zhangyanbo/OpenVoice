import XCTest
@testable import OpenVoice

final class DictationPromptTests: XCTestCase {
    func testSelectedTextAlwaysUsesCommandPrompt() {
        let context = DictationContext(selectedText: "This is a long sentence.")

        let system = DictationController.systemPrompt(
            mode: .dictation,
            context: context,
            terms: ""
        )
        let user = DictationController.userPrompt(
            mode: .dictation,
            context: context,
            transcript: "写短一点"
        )

        XCTAssertTrue(system.contains("必须视为作用于这段文字的操作指令"))
        XCTAssertTrue(system.contains("绝不要把口述指令本身当作普通听写内容"))
        XCTAssertFalse(system.contains("如果转录内容是对这段文字的操作指令"))
        XCTAssertTrue(user.contains("用户对选中文字发出的口述指令：\n写短一点"))
        XCTAssertFalse(user.contains("语音转录结果："))
    }

    func testDictationWithoutSelectionKeepsOrdinaryPrompt() {
        let context = DictationContext()

        let system = DictationController.systemPrompt(
            mode: .dictation,
            context: context,
            terms: ""
        )
        let user = DictationController.userPrompt(
            mode: .dictation,
            context: context,
            transcript: "今天天气很好"
        )

        XCTAssertTrue(system.contains("你是一个语音输入法的后处理器"))
        XCTAssertFalse(system.contains("必须视为作用于这段文字的操作指令"))
        XCTAssertTrue(user.contains("语音转录结果：\n今天天气很好"))
    }
}
