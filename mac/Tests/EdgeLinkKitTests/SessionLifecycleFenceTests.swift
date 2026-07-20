import XCTest
@testable import EdgeLinkKit

final class SessionLifecycleFenceTests: XCTestCase {
    func testStopIsHonoredAfterCurrentSessionEnds() {
        var fence = SessionLifecycleFence<String>()
        fence.register("first")
        let eventGeneration = fence.generation

        fence.remove("first")

        XCTAssertTrue(fence.shouldHonorStop(from: eventGeneration))
    }

    func testLateStopDoesNotEndReplacementSession() {
        var fence = SessionLifecycleFence<String>()
        fence.register("first")
        let eventGeneration = fence.generation
        fence.register("second")

        fence.remove("first")

        XCTAssertFalse(fence.shouldHonorStop(from: eventGeneration))
        XCTAssertEqual(fence.activeSessionCount, 1)
    }

    func testResetInvalidatesAlreadyQueuedStop() {
        var fence = SessionLifecycleFence<String>()
        fence.register("first")
        let eventGeneration = fence.generation

        fence.reset()
        fence.register("second")

        XCTAssertFalse(fence.shouldHonorStop(from: eventGeneration))
        XCTAssertTrue(fence.hasActiveSessions)
    }
}
