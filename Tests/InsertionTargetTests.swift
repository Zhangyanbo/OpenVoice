import XCTest
@testable import OpenVoice

final class InsertionTargetTests: XCTestCase {
    func testRecordingEndTargetWinsWhenUserMovesToAnotherApp() {
        let source = InsertionTarget(pid: 10, element: nil, selectionRange: nil)
        let destination = InsertionTarget(pid: 20, element: nil, selectionRange: nil)

        let resolved = DictationController.resolvedInsertionTarget(
            recordingStart: source,
            recordingEnd: destination
        )

        XCTAssertEqual(resolved?.pid, destination.pid)
    }

    func testSameTargetKeepsRecordingStartSelectionMetadata() {
        let source = InsertionTarget(
            pid: 10,
            element: nil,
            selectionRange: CFRange(location: 4, length: 8),
            requiresPasteInsertion: true
        )
        let destination = InsertionTarget(pid: 10, element: nil, selectionRange: nil)

        let resolved = DictationController.resolvedInsertionTarget(
            recordingStart: source,
            recordingEnd: destination
        )

        XCTAssertEqual(resolved?.selectionRange?.location, 4)
        XCTAssertEqual(resolved?.selectionRange?.length, 8)
        XCTAssertEqual(resolved?.requiresPasteInsertion, true)
    }

    func testMissingRecordingEndTargetFallsBackToRecordingStart() {
        let source = InsertionTarget(pid: 10, element: nil, selectionRange: nil)

        let resolved = DictationController.resolvedInsertionTarget(
            recordingStart: source,
            recordingEnd: nil
        )

        XCTAssertEqual(resolved?.pid, source.pid)
    }
}
