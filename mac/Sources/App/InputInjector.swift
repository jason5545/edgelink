import ApplicationServices
import CoreGraphics
import Foundation

final class InputInjector {
    enum MouseButton: String {
        case left
        case right
        case middle

        var cgButton: CGMouseButton {
            switch self {
            case .left:
                return .left
            case .right:
                return .right
            case .middle:
                return .center
            }
        }

        var downType: CGEventType {
            switch self {
            case .left:
                return .leftMouseDown
            case .right:
                return .rightMouseDown
            case .middle:
                return .otherMouseDown
            }
        }

        var upType: CGEventType {
            switch self {
            case .left:
                return .leftMouseUp
            case .right:
                return .rightMouseUp
            case .middle:
                return .otherMouseUp
            }
        }
    }

    enum KeyModifier: String {
        case command = "cmd"
        case control = "ctrl"
        case option = "alt"
        case shift

        var flag: CGEventFlags {
            switch self {
            case .command:
                return .maskCommand
            case .control:
                return .maskControl
            case .option:
                return .maskAlternate
            case .shift:
                return .maskShift
            }
        }
    }

    private let source = CGEventSource(stateID: .hidSystemState)

    func accessibilityTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func movePointer(dx: Double, dy: Double) {
        guard let current = CGEvent(source: nil)?.location else { return }
        let next = CGPoint(x: current.x + dx, y: current.y + dy)
        CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: next,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    func click(_ button: MouseButton = .left) {
        guard let current = CGEvent(source: nil)?.location else { return }
        CGEvent(
            mouseEventSource: source,
            mouseType: button.downType,
            mouseCursorPosition: current,
            mouseButton: button.cgButton
        )?.post(tap: .cghidEventTap)
        CGEvent(
            mouseEventSource: source,
            mouseType: button.upType,
            mouseCursorPosition: current,
            mouseButton: button.cgButton
        )?.post(tap: .cghidEventTap)
    }

    func scroll(dx: Double, dy: Double) {
        CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy.rounded()),
            wheel2: Int32(dx.rounded()),
            wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    func typeText(_ text: String) {
        var utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        keyDown?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        keyUp?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        keyUp?.post(tap: .cghidEventTap)
    }

    func pressKey(_ key: String, modifiers: Set<KeyModifier> = []) {
        guard let keyCode = KeyCodeMap.code(for: key) else { return }
        let flags = modifiers.reduce(CGEventFlags()) { partial, modifier in
            partial.union(modifier.flag)
        }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}

private enum KeyCodeMap {
    private static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "delete": 51, "escape": 53, "left": 123, "right": 124,
        "down": 125, "up": 126
    ]

    static func code(for key: String) -> CGKeyCode? {
        codes[key.lowercased()]
    }
}
