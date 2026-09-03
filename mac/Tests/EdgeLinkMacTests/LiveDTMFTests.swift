import XCTest

final class LiveDTMFTests: XCTestCase {
    func testAppendsSingleCharacter() {
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "", current: "5"), "5")
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "1", current: "12"), "2")
    }

    func testPasteMultipleCharactersSendsWholeSequence() {
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "", current: "123"), "123")
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "", current: "12,34"), "12,34")
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "1", current: "12,3"), "2,3")
    }

    func testDeletionAndReplacementReturnNil() {
        XCTAssertNil(LiveDTMF.liveDTMFDelta(previous: "12", current: "1"))
        XCTAssertNil(LiveDTMF.liveDTMFDelta(previous: "1", current: ""))
        XCTAssertNil(LiveDTMF.liveDTMFDelta(previous: "1", current: "2"))
        XCTAssertNil(LiveDTMF.liveDTMFDelta(previous: "", current: ""))
        XCTAssertNil(LiveDTMF.liveDTMFDelta(previous: "12", current: "13"))
    }

    func testIllegalCharacterReturnsNil() {
        XCTAssertNil(LiveDTMF.liveDTMFDelta(previous: "", current: "a"))
        XCTAssertNil(LiveDTMF.liveDTMFDelta(previous: "5", current: "5a"))
        XCTAssertNil(LiveDTMF.liveDTMFDelta(previous: "", current: "５"))
        XCTAssertNil(LiveDTMF.liveDTMFDelta(previous: "", current: ","))
    }

    func testFullWidthAndPauseNormalization() {
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "", current: "＊"), "*")
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "", current: "＃"), "#")
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "", current: "1＊＃"), "1*#")
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "", current: "1p2"), "1,2")
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "", current: "1P2"), "1,2")
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "", current: "1，2"), "1,2")
    }

    func testSkippedSeparators() {
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "", current: "1 -2"), "12")
        XCTAssertEqual(LiveDTMF.liveDTMFDelta(previous: "", current: " 5 "), "5")
        XCTAssertNil(LiveDTMF.liveDTMFDelta(previous: "", current: "-"))
    }
}
