import XCTest

final class MirrorPointerRoutingTests: XCTestCase {
    func testTouchActionsRideCastChannelDuringMirror() {
        for action in ["down", "move", "up", "cancel", "rightUp", "hover"] {
            XCTAssertTrue(
                MirrorPointerRouting.usesCastChannel(action: action, xiaomiMirrorActive: true),
                "\(action) should stay on the cast channel during mirror"
            )
        }
    }

    func testWheelBypassesCastChannelDuringMirror() {
        XCTAssertFalse(
            MirrorPointerRouting.usesCastChannel(action: "wheel", xiaomiMirrorActive: true),
            "wheel must fall back to the EdgeLink control envelope because the native mirror input stack drops it"
        )
    }

    func testEverythingUsesEnvelopeWhenMirrorInactive() {
        for action in ["down", "move", "up", "wheel"] {
            XCTAssertFalse(
                MirrorPointerRouting.usesCastChannel(action: action, xiaomiMirrorActive: false),
                "\(action) should use the control envelope when no mirror is active"
            )
        }
    }
}
