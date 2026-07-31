import AppKit
import Foundation

enum LyraPairingPresenter {
    static func showPasskey(_ code: String) {
        present(
            title: String(localized: "小米互聯配對"),
            message: String(localized: "在手機上輸入配對碼：\(code)"),
            code: code
        )
    }

    static func showCompareCode(_ code: String) {
        present(
            title: String(localized: "確認配對碼"),
            message: String(localized: "請確認手機上顯示的配對碼與此相同：\(code)"),
            code: code
        )
    }

    private static func present(title: String, message: String, code: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "好"))
            alert.runModal()
        }
    }
}
