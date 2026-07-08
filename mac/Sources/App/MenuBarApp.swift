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

                Divider()

                Toggle(
                    "Mac Notifications",
                    isOn: Binding(
                        get: { runtime.macNotificationSyncEnabled },
                        set: { runtime.setMacNotificationSyncEnabled($0) }
                    )
                )
                .toggleStyle(.switch)

                Button {
                    runtime.viewPhoneScreen()
                } label: {
                    Label("View Phone Screen", systemImage: "iphone")
                }
                .disabled(!runtime.isConnected)

                Divider()

                if runtime.isPairing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(runtime.pairingStatus)
                            .font(.subheadline)
                        if !runtime.pairingPeerName.isEmpty {
                            Text(runtime.pairingPeerName)
                                .lineLimit(1)
                        }
                        if !runtime.pairingSAS.isEmpty {
                            PairingView(sasDisplay: runtime.pairingSAS) {
                                runtime.acceptPairing()
                            }
                            .disabled(!runtime.canAcceptPairing)
                        }
                    }
                } else {
                    Button("Pair New Device") {
                        runtime.startPairing()
                    }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .frame(width: 280)
        }
        .menuBarExtraStyle(.window)
    }
}
