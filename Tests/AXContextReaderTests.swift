import XCTest
@testable import OpenVoice

final class AXContextReaderTests: XCTestCase {
    func testCopyFallbackDoesNotRequireFocusedElement() {
        let target = InsertionTarget(pid: 1, element: nil, selectionRange: nil)

        XCTAssertTrue(AXContextReader.shouldUseCopyFallback(
            readSelectedText: true,
            selectedText: nil,
            target: target
        ))
    }

    func testCopyFallbackSkipsKnownSecureField() {
        let target = InsertionTarget(
            pid: 1,
            element: nil,
            selectionRange: nil,
            isSecureTextField: true
        )

        XCTAssertFalse(AXContextReader.shouldUseCopyFallback(
            readSelectedText: true,
            selectedText: nil,
            target: target
        ))
    }

    func testCopyFallbackSkipsExistingSelectionAndMissingTarget() {
        let target = InsertionTarget(pid: 1, element: nil, selectionRange: nil)

        XCTAssertFalse(AXContextReader.shouldUseCopyFallback(
            readSelectedText: true,
            selectedText: "已有选区",
            target: target
        ))
        XCTAssertFalse(AXContextReader.shouldUseCopyFallback(
            readSelectedText: true,
            selectedText: nil,
            target: nil
        ))
    }

    func testSelectedTextAtLimitIsNotTruncated() {
        let source = String(repeating: "文", count: AXContextReader.selectedTextLimit)
        let result = AXContextReader.limitedSelectedText(source)

        XCTAssertEqual(result.text.count, 5_000)
        XCTAssertFalse(result.wasTruncated)
    }

    func testSelectedTextOverLimitKeepsFirstFiveThousandCharacters() {
        let source = String(repeating: "a", count: AXContextReader.selectedTextLimit) + "TAIL"
        let result = AXContextReader.limitedSelectedText(source)

        XCTAssertEqual(result.text, String(repeating: "a", count: 5_000))
        XCTAssertTrue(result.wasTruncated)
    }
}
