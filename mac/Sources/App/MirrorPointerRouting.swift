import Foundation

struct MirrorWheelDragStep {
    let action: String
    let x: Int
    let y: Int
}

enum MirrorPointerRouting {
    static func usesCastChannel(action: String, xiaomiMirrorActive: Bool) -> Bool {
        xiaomiMirrorActive
    }

    // The native mirror input stack drops ProtoMouse wheel actions, but it
    // does inject drags as real touch MotionEvents — so a wheel tick becomes
    // a synthetic vertical drag (down → moves → up), which scrolls exactly
    // like the official client's drag. Distance and direction mirror the
    // Android accessibility fallback (RemoteInputService): |dy| * 2.6 px
    // clamped to 96...720, positive wheelDy swipes downward.
    static let wheelDragMoveCount = 4
    static let wheelDragMaxDistance = 720.0
    static let wheelDragMinDistance = 96.0
    static let wheelDragDistancePerUnit = 2.6

    static func wheelDragSteps(x: Int, y: Int, wheelDy: Int) -> [MirrorWheelDragStep] {
        guard wheelDy != 0 else { return [] }
        let distance = min(
            wheelDragMaxDistance,
            max(wheelDragMinDistance, abs(Double(wheelDy)) * wheelDragDistancePerUnit)
        )
        let direction = wheelDy > 0 ? 1.0 : -1.0
        let endY = max(0, Int((Double(y) + distance * direction).rounded()))
        guard endY != y else { return [] }
        var steps = [MirrorWheelDragStep(action: "down", x: x, y: y)]
        for index in 1...wheelDragMoveCount {
            let fraction = Double(index) / Double(wheelDragMoveCount)
            let stepY = y + Int((Double(endY - y) * fraction).rounded())
            steps.append(MirrorWheelDragStep(action: "move", x: x, y: stepY))
        }
        steps.append(MirrorWheelDragStep(action: "up", x: x, y: endY))
        return steps
    }
}
