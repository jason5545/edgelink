import EdgeLinkKit
import Foundation
import XCTest

final class LyraCastChannelMessagesTests: XCTestCase {
    func testFrameRoundTrip() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let frame = LyraCastMessageCodec.encodeFrame(type: LyraCastMessageType.screenAction, payload: payload)
        XCTAssertEqual(frame, Data([12, 4, 0, 0, 0, 0xDE, 0xAD, 0xBE, 0xEF]))
        let (type, decoded) = try LyraCastMessageCodec.decodeFrame(frame)
        XCTAssertEqual(type, 12)
        XCTAssertEqual(decoded, payload)
    }

    func testFrameTruncated() {
        XCTAssertThrowsError(try LyraCastMessageCodec.decodeFrame(Data([18, 10, 0, 0, 0, 1]))) { error in
            XCTAssertEqual(error as? LyraCastMessageCodec.FrameError, .truncated)
        }
    }

    func testFrameLengthMismatch() {
        XCTAssertThrowsError(try LyraCastMessageCodec.decodeFrame(Data([18, 1, 0, 0, 0, 1, 2]))) { error in
            XCTAssertEqual(error as? LyraCastMessageCodec.FrameError, .lengthMismatch)
        }
    }

    func testCapabilitiesMatchesOfficialBytes() throws {
        var capabilities = LyraCastCapabilities()
        capabilities.entries = [LyraCastCapabilities.Entry(
            key: "com.xiaomi.mirror",
            value: "app_drag_drop;productName_myron;"
        )]
        let frame = LyraCastMessageCodec.encodeFrame(
            type: LyraCastMessageType.capabilities,
            payload: capabilities.encode()
        )
        var expected = Data([0x40, 0x37, 0x00, 0x00, 0x00, 0x0A, 0x35, 0x0A, 0x11])
        expected.append(Data("com.xiaomi.mirror".utf8))
        expected.append(contentsOf: [0x12, 0x20])
        expected.append(Data("app_drag_drop;productName_myron;".utf8))
        XCTAssertEqual(frame.count, 60)
        XCTAssertEqual(frame, expected)

        let (type, payload) = try LyraCastMessageCodec.decodeFrame(expected)
        XCTAssertEqual(type, LyraCastMessageType.capabilities)
        let decoded = try LyraCastCapabilities.decode(payload)
        XCTAssertEqual(decoded, capabilities)
        XCTAssertFalse(decoded.isHandshake)
    }

    func testDeviceInfoMatchesOfficialBytes() throws {
        let json = #"{"os":3,"android_version":36,"mirror_version":170130}"#
        var event = LyraCastSimpleEvent()
        event.sessionId = 7686894505455899311
        event.event = LyraCastSimpleEvent.eventDeviceInfo
        event.stringValue = json
        let frame = LyraCastMessageCodec.encodeFrame(
            type: LyraCastMessageType.simpleEvent,
            payload: event.encode()
        )
        var expected = Data([0x12, 0x43, 0x00, 0x00, 0x00, 0x08, 0xAF, 0xA5, 0xE7, 0xBC, 0xB6, 0xBA, 0xD5, 0xD6, 0x6A, 0x10, 0x26, 0x1A, 0x35])
        expected.append(Data(json.utf8))
        XCTAssertEqual(frame.count, 72)
        XCTAssertEqual(frame, expected)

        let (type, payload) = try LyraCastMessageCodec.decodeFrame(expected)
        XCTAssertEqual(type, LyraCastMessageType.simpleEvent)
        let decoded = try LyraCastSimpleEvent.decode(payload)
        XCTAssertEqual(decoded.event, 38)
        XCTAssertEqual(decoded.sessionId, 7686894505455899311)
        XCTAssertEqual(decoded.stringValue, json)
    }

    func testMirrorCallStopMatchesOfficialBytes() throws {
        var event = LyraCastSimpleEvent()
        event.event = LyraCastSimpleEvent.eventMirrorCallStop
        event.stringValue = ""
        let frame = LyraCastMessageCodec.encodeFrame(
            type: LyraCastMessageType.simpleEvent,
            payload: event.encode()
        )
        let expected = Data([0x12, 0x04, 0x00, 0x00, 0x00, 0x10, 0x19, 0x1A, 0x00])
        XCTAssertEqual(frame, expected)

        let (type, payload) = try LyraCastMessageCodec.decodeFrame(expected)
        XCTAssertEqual(type, LyraCastMessageType.simpleEvent)
        let decoded = try LyraCastSimpleEvent.decode(payload)
        XCTAssertEqual(decoded.event, 25)
        XCTAssertNil(decoded.sessionId)
        XCTAssertEqual(decoded.stringValue, "")
    }

    func testMirrorCallKeyOfficialShape() throws {
        let json = #"{"keyBytes":[48,89,48,19,6,7,42,-122,58,-100,2,1,3,-122,80,3,2,1,-128,-128,1,1,3,66,0,4,120,-10,-90,-61]}"#
        let payloadLength = UInt8(4 + json.utf8.count)
        let officialPrefix = Data([0x12, payloadLength, 0x00, 0x00, 0x00, 0x10, 0x17, 0x1A, UInt8(json.utf8.count)])
        var event = LyraCastSimpleEvent()
        event.event = LyraCastSimpleEvent.eventMirrorCallKey
        event.stringValue = json
        let frame = LyraCastMessageCodec.encodeFrame(
            type: LyraCastMessageType.simpleEvent,
            payload: event.encode()
        )
        XCTAssertEqual(frame, officialPrefix + Data(json.utf8))

        let (type, payload) = try LyraCastMessageCodec.decodeFrame(frame)
        XCTAssertEqual(type, LyraCastMessageType.simpleEvent)
        let decoded = try LyraCastSimpleEvent.decode(payload)
        XCTAssertEqual(decoded.event, 23)
        XCTAssertNil(decoded.sessionId)
        XCTAssertTrue(decoded.stringValue?.hasPrefix(#"{"keyBytes":[48,89,48,19,6,7,42,-122,"#) ?? false)
    }

    func testOpenMirrorScreenMatchesOfficialBytes() throws {
        let action = LyraCastScreenAction.openMirrorScreen(sessionId: 1785467173613)
        let frame = LyraCastMessageCodec.encodeFrame(
            type: LyraCastMessageType.screenAction,
            payload: action.encode()
        )
        let expected = Data([0x0C, 0x09, 0x00, 0x00, 0x00, 0x08, 0xED, 0xF5, 0x8B, 0xB1, 0xFB, 0x33, 0x18, 0x04])
        XCTAssertEqual(frame, expected)

        let (type, payload) = try LyraCastMessageCodec.decodeFrame(expected)
        XCTAssertEqual(type, LyraCastMessageType.screenAction)
        let decoded = try LyraCastScreenAction.decode(payload)
        XCTAssertEqual(decoded.sessionId, 1785467173613)
        XCTAssertEqual(decoded.action, LyraCastScreenAction.Action.openMirrorScreen.rawValue)
        XCTAssertEqual(decoded.screenId, 0)
        XCTAssertEqual(decoded, action)
    }

    func testScreenActionRoundTripAllFields() throws {
        var action = LyraCastScreenAction.openMirrorScreen(sessionId: 1785501613039, screenId: 2)
        action.width = 1080
        action.height = 2400
        action.appId = "com.example.app"
        action.openMirrorScreenFrom = 10
        action.density = 440
        action.statusBarHeight = 80
        action.navBarHeight = 120
        action.backgroundMode = true
        action.prepareResult = 6
        action.supportFlipType = 2
        action.isSupportDisplayAdjust = true
        action.theme = 1
        action.closeScreenReason = 3
        action.preferShowImeInSubscreen = true
        let decoded = try LyraCastScreenAction.decode(action.encode())
        XCTAssertEqual(decoded, action)
    }

    func testCloseScreenRoundTrip() throws {
        let action = LyraCastScreenAction.closeScreen(sessionId: 42, screenId: 0)
        let frame = LyraCastMessageCodec.encodeFrame(
            type: LyraCastMessageType.screenAction,
            payload: action.encode()
        )
        let (type, payload) = try LyraCastMessageCodec.decodeFrame(frame)
        XCTAssertEqual(type, LyraCastMessageType.screenAction)
        let decoded = try LyraCastScreenAction.decode(payload)
        XCTAssertEqual(decoded.action, LyraCastScreenAction.Action.closeScreen.rawValue)
        XCTAssertEqual(decoded.sessionId, 42)
    }

    // Wire layout checked against the phone-side descriptor
    // (com.xiaomi.mirror.message.proto.Keyboard, Mirror.apk): session_id=1,
    // screen_id=2, key_event=3{code=1, meta_info=2, down=3}, text=4,
    // is_android_key=5.
    func testKeyboardKeyEventWireLayout() throws {
        let message = LyraCastKeyboard.key(
            sessionId: 1785501613039,
            androidKeyCode: 29,
            metaInfo: 1,
            down: true
        )
        let encoded = message.encode()
        // field 1 (session_id varint)
        XCTAssertEqual(encoded[encoded.startIndex], 0x08)
        // must contain field 3 (key_event, length-delimited): tag 0x1A
        XCTAssertTrue(encoded.contains(0x1A))
        // field 5 (is_android_key bool true): tag 0x28 value 0x01
        XCTAssertEqual(encoded.suffix(2), [0x28, 0x01])
        let decoded = try LyraCastKeyboard.decode(encoded)
        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.keyEvent?.code, 29)
        XCTAssertEqual(decoded.keyEvent?.metaInfo, 1)
        XCTAssertEqual(decoded.keyEvent?.down, true)
        XCTAssertTrue(decoded.isAndroidKey)
        XCTAssertNil(decoded.text)
    }

    func testKeyboardKeyUpOmitsDownFlag() throws {
        let message = LyraCastKeyboard.key(
            sessionId: 42,
            androidKeyCode: 66,
            metaInfo: 0,
            down: false
        )
        let decoded = try LyraCastKeyboard.decode(message.encode())
        XCTAssertEqual(decoded.keyEvent?.down, false)
        XCTAssertEqual(decoded.keyEvent?.code, 66)
    }

    func testKeyboardCommittedTextRoundTrip() throws {
        let message = LyraCastKeyboard.committedText(sessionId: 42, text: "你好")
        let frame = LyraCastMessageCodec.encodeFrame(
            type: LyraCastMessageType.keyboard,
            payload: message.encode()
        )
        let (type, payload) = try LyraCastMessageCodec.decodeFrame(frame)
        XCTAssertEqual(type, LyraCastMessageType.keyboard)
        XCTAssertEqual(type, 4)
        let decoded = try LyraCastKeyboard.decode(payload)
        XCTAssertEqual(decoded.text, "你好")
        XCTAssertNil(decoded.keyEvent)
        XCTAssertFalse(decoded.isAndroidKey)
    }

    // Wire layout checked against the phone-side descriptor
    // (com.xiaomi.mirror.message.proto.Command, Mirror.apk): screen_id=1,
    // down=2, command_type=3 (HOME=0, BACK=1, MENU=2). HOME is the proto3
    // default and is not serialized.
    func testCommandWireLayout() throws {
        let tap = LyraCastCommand.tap(.back)
        XCTAssertEqual(tap.count, 2)
        XCTAssertTrue(tap[0].down)
        XCTAssertFalse(tap[1].down)

        let encoded = tap[0].encode()
        // down=true: field 2 tag 0x10 value 0x01; command_type=BACK: field 3
        // tag 0x18 value 0x01. screen_id=0 omitted.
        XCTAssertEqual(Array(encoded), [0x10, 0x01, 0x18, 0x01])
        let decoded = try LyraCastCommand.decode(encoded)
        XCTAssertEqual(decoded, tap[0])

        let frame = LyraCastMessageCodec.encodeFrame(
            type: LyraCastMessageType.command,
            payload: encoded
        )
        let (type, payload) = try LyraCastMessageCodec.decodeFrame(frame)
        XCTAssertEqual(type, 9)
        XCTAssertEqual(try LyraCastCommand.decode(payload), tap[0])
    }

    func testCommandHomeSerializesEmpty() throws {
        // HOME=0 is the proto3 default: a home tap encodes only the down bit.
        let tap = LyraCastCommand.tap(.home)
        XCTAssertEqual(Array(tap[0].encode()), [0x10, 0x01])
        XCTAssertTrue(tap[1].encode().isEmpty)
        let decoded = try LyraCastCommand.decode(tap[0].encode())
        XCTAssertEqual(decoded.commandType, .home)
        XCTAssertTrue(decoded.down)
    }
}
