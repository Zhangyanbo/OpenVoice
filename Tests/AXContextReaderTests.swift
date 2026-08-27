import XCTest
@testable import OpenVoice

final class AXContextReaderTests: XCTestCase {
    func testSelectedSubstringUsesAXUTF16Range() {
        let value = "A🙂选中文字B"
        let nsRange = (value as NSString).range(of: "🙂选中文字")
        let range = CFRange(location: nsRange.location, length: nsRange.length)

        XCTAssertEqual(
            AXContextReader.selectedSubstring(in: value, range: range),
            "🙂选中文字"
        )
    }

    func testSelectedSubstringRejectsEmptyAndInvalidRanges() {
        XCTAssertNil(
            AXContextReader.selectedSubstring(
                in: "原文",
                range: CFRange(location: 1, length: 0)
            )
        )
        XCTAssertNil(
            AXContextReader.selectedSubstring(
                in: "原文",
                range: CFRange(location: 1, length: 10)
            )
        )
    }

}
