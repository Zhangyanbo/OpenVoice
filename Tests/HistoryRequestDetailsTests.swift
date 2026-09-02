import XCTest
@testable import OpenVoice

final class HistoryRequestDetailsTests: XCTestCase {
    func testRequestDetailsRoundTripWithHistoryEntry() throws {
        let details = HistoryStore.RequestDetails(
            audioByteCount: 320_044,
            recognitionLanguage: "zh",
            transcriptionPrompt: "OpenVoice, MacroNet",
            rawTranscript: "这是语音识别的原始结果。",
            systemPrompt: "system",
            userPrompt: "user")
        let entry = HistoryStore.Entry(
            text: "这是整理后的结果。",
            mode: "语音",
            appName: "Notes",
            requestDetails: details)

        let decoded = try JSONDecoder().decode(
            HistoryStore.Entry.self,
            from: JSONEncoder().encode(entry))

        XCTAssertEqual(decoded.requestDetails, details)
    }

    func testOlderHistoryEntryWithoutRequestDetailsStillDecodes() throws {
        let entry = HistoryStore.Entry(text: "旧记录", mode: "语音", appName: nil)
        let encoded = try JSONEncoder().encode(entry)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "requestDetails")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(HistoryStore.Entry.self, from: legacyData)

        XCTAssertEqual(decoded.text, "旧记录")
        XCTAssertNil(decoded.requestDetails)
    }
}
