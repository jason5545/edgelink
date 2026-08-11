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
    // like the official client's drag. TrackPal/edge scrolling emits
    // pixel-unit deltas of only a few px per 50 ms coalesced tick (see
    // ~/Library/Logs/TrackPal.log), so the min clamp dominates slow scrolls:
    // 2.0 px/unit with a 48 px floor keeps slow scrolls gentle while fast
    // flicks scale up. The floor must clear Android's touch slop (~8 dp ≈
    // 24 px at 3x density) comfortably or the drag classifies as a tap.
    // Positive wheelDy swipes downward.
    static let wheelDragMoveCount = 6
    static let wheelDragMaxDistance = 720.0
    static let wheelDragMinDistance = 48.0
    static let wheelDragDistancePerUnit = 2.0

    static func wheelDragSignedDistance(wheelDy: Int) -> Int {
        guard wheelDy != 0 else { return 0 }
        let magnitude = min(
            wheelDragMaxDistance,
            max(wheelDragMinDistance, abs(Double(wheelDy)) * wheelDragDistancePerUnit)
        )
        return Int(magnitude.rounded()) * (wheelDy > 0 ? 1 : -1)
    }

    static func wheelDragMoveSteps(x: Int, fromY: Int, toY: Int) -> [MirrorWheelDragStep] {
        guard toY != fromY else { return [] }
        var steps: [MirrorWheelDragStep] = []
        for index in 1...wheelDragMoveCount {
            let fraction = Double(index) / Double(wheelDragMoveCount)
            let stepY = fromY + Int((Double(toY - fromY) * fraction).rounded())
            steps.append(MirrorWheelDragStep(action: "move", x: x, y: stepY))
        }
        return steps
    }

    static func wheelDragSteps(x: Int, y: Int, wheelDy: Int) -> [MirrorWheelDragStep] {
        let signedDistance = wheelDragSignedDistance(wheelDy: wheelDy)
        guard signedDistance != 0 else { return [] }
        let endY = max(0, y + signedDistance)
        guard endY != y else { return [] }
        return [MirrorWheelDragStep(action: "down", x: x, y: y)]
            + wheelDragMoveSteps(x: x, fromY: y, toY: endY)
            + [MirrorWheelDragStep(action: "up", x: x, y: endY)]
    }
}
