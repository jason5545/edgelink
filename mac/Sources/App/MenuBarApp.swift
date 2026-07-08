import EdgeLinkKit
import SwiftUI

@main
struct EdgeLinkMacApp: App {
    @State private var pairingCode = "260 433"

    var body: some Scene {
        MenuBarExtra("EdgeLink", systemImage: "link") {
            VStack(alignment: .leading, spacing: 12) {
                Text("EdgeLink")
                    .font(.headline)

                Text("ID 949 758 990")
                    .monospacedDigit()

                Divider()

                PairingView(sasDisplay: pairingCode) {
                    // M1 wires this to pin the peer key after both confirmations arrive.
                }
            }
            .padding()
            .frame(width: 280)
        }
        .menuBarExtraStyle(.window)
    }
}
