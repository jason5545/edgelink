import XCTest

final class MirrorPointerRoutingTests: XCTestCase {
    func testAllActionsRideCastChannelDuringMirror() {
        for action in ["down", "move", "up", "cancel", "rightUp", "hover", "wheel"] {
            XCTAssertTrue(
                MirrorPointerRouting.usesCastChannel(action: action, xiaomiMirrorActive: true),
                "\(action) should stay on the cast channel during mirror"
            )
        }
    }

    func testEverythingUsesEnvelopeWhenMirrorInactive() {
        for action in ["down", "move", "up", "wheel"] {
            XCTAssertFalse(
                MirrorPointerRouting.usesCastChannel(action: action, xiaomiMirrorActive: false),
                "\(action) should use the control envelope when no mirror is active"
            )
        }
    }

    func testWheelDragStepsSwipeDownForPositiveWheelDy() {
        let steps = MirrorPointerRouting.wheelDragSteps(x: 500, y: 300, wheelDy: 120)
        XCTAssertEqual(steps.first?.action, "down")
        XCTAssertEqual(steps.first?.x, 500)
        XCTAssertEqual(steps.first?.y, 300)
        XCTAssertEqual(steps.last?.action, "up")
        XCTAssertEqual(steps.last?.y, 300 + 312, "120 * 2.6 = 312 px downward swipe")
        let moves = steps.dropFirst().dropLast()
        XCTAssertEqual(moves.count, MirrorPointerRouting.wheelDragMoveCount)
        XCTAssertTrue(moves.allSatisfy { $0.action == "move" && $0.x == 500 })
        XCTAssertEqual(moves.map(\.y), moves.map(\.y).sorted(), "moves march monotonically toward the end")
        for step in steps.dropFirst() {
            XCTAssertGreaterThan(step.y, 300)
        }
    }

    func testWheelDragStepsSwipeUpForNegativeWheelDy() {
        let steps = MirrorPointerRouting.wheelDragSteps(x: 500, y: 600, wheelDy: -120)
        XCTAssertEqual(steps.first?.action, "down")
        XCTAssertEqual(steps.last?.action, "up")
        XCTAssertEqual(steps.last?.y, 600 - 312)
        for step in steps.dropFirst() {
            XCTAssertLessThan(step.y, 600)
        }
    }

    func testWheelDragStepsClampDistance() {
        let tiny = MirrorPointerRouting.wheelDragSteps(x: 100, y: 1000, wheelDy: 1)
        XCTAssertEqual(tiny.last?.y, 1000 + 96, "distance clamps to the 96 px minimum")
        let huge = MirrorPointerRouting.wheelDragSteps(x: 100, y: 1000, wheelDy: 100_000)
        XCTAssertEqual(huge.last?.y, 1000 + 720, "distance clamps to the 720 px maximum")
    }

    func testWheelDragStepsClampAtTopEdge() {
        let steps = MirrorPointerRouting.wheelDragSteps(x: 100, y: 50, wheelDy: -120)
        XCTAssertEqual(steps.last?.y, 0, "upward swipe clamps to y=0")
    }

    func testWheelDragStepsDropZeroLengthDrag() {
        XCTAssertTrue(MirrorPointerRouting.wheelDragSteps(x: 100, y: 200, wheelDy: 0).isEmpty)
        XCTAssertTrue(
            MirrorPointerRouting.wheelDragSteps(x: 100, y: 0, wheelDy: -120).isEmpty,
            "a drag fully clamped to zero length must not become a tap"
        )
    }
}
