import EdgeLinkKit
import SwiftUI

@main
struct EdgeLinkMacApp: App {
    @StateObject private var runtime = EdgeLinkRuntime()

    var body: some Scene {
        MenuBarExtra("EdgeLink", systemImage: runtime.isConnected ? "link.circle.fill" : "link.circle") {
            VStack(alignment: .leading, spacing: 12) {
                Text("EdgeLink")
                    .font(.headline)

                Text("ID \(runtime.localDeviceId)")
                    .monospacedDigit()

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(runtime.connectionStatus)
                        .font(.subheadline)
                    Text(runtime.peerName)
                        .lineLimit(1)
                    if !runtime.peerDeviceId.isEmpty {
                        Text(runtime.peerDeviceId)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .frame(width: 280)
        }
        .menuBarExtraStyle(.window)
    }
}
