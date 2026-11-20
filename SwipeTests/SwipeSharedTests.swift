import XCTest
@testable import Swipe

final class SwipeSharedTests: XCTestCase {
    func testSentenceStartFormattingCapitalizesAndOmitsLeadingSpace() {
        let settings = DictationSettings()
        let formatted = TranscriptFormatter.formatForInsertion(
            rawTranscript: "hello world",
            contextBeforeInput: "",
            settings: settings
        )
        XCTAssertEqual(formatted, "Hello world")
    }

    func testMidSentenceFormattingAddsLeadingSpaceAndLowercases() {
        let settings = DictationSettings()
        let formatted = TranscriptFormatter.formatForInsertion(
            rawTranscript: "And then we shipped it",
            contextBeforeInput: "We built a prototype",
            settings: settings
        )
        XCTAssertEqual(formatted, " and then we shipped it")
    }

    func testMidSentencePreservesStandalonePronounI() {
        let settings = DictationSettings()
        let formatted = TranscriptFormatter.formatForInsertion(
            rawTranscript: "I think that works",
            contextBeforeInput: "Honestly,",
            settings: settings
        )
        XCTAssertEqual(formatted, " I think that works")
    }

    func testPunctuationTidyCollapsesExtraSpaces() {
        let settings = DictationSettings()
        let formatted = TranscriptFormatter.formatForInsertion(
            rawTranscript: "looks  great ,  ship it !",
            contextBeforeInput: "Update: ",
            settings: settings
        )
        XCTAssertEqual(formatted, "looks great, ship it!")
    }

    func testHostWarmSessionWindowExpiration() {
        let now = Date()
        let warm = DictationSnapshot(
            phase: .idle,
            hostArmed: true,
            hostHeartbeatAt: now.addingTimeInterval(-3)
        )
        XCTAssertTrue(warm.isHostSessionWarm(now: now))

        let stale = DictationSnapshot(
            phase: .idle,
            hostArmed: true,
            hostHeartbeatAt: now.addingTimeInterval(-(DictationConfig.warmSessionHeartbeatTTL + 2))
        )
        XCTAssertFalse(stale.isHostSessionWarm(now: now))
    }

    func testSnapshotCodableRoundTrip() throws {
        let original = DictationSnapshot(
            phase: .listening,
            partialText: "testing dictation",
            finalText: "",
            audioLevels: [0.1, 0.5, 0.9],
            hostArmed: true,
            hostHeartbeatAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOnDevice: true,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DictationSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
