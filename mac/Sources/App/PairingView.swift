import SwiftUI

struct PairingView: View {
    let sasDisplay: String
    let onAccept: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(sasDisplay)
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)

            Button("Accept") {
                onAccept()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
    }
}
