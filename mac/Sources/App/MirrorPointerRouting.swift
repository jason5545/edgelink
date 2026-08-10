import Foundation

enum MirrorPointerRouting {
    static func usesCastChannel(action: String, xiaomiMirrorActive: Bool) -> Bool {
        xiaomiMirrorActive && action != "wheel"
    }
}
