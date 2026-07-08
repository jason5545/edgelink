import EdgeLinkKit
import SwiftUI

@main
struct EdgeLinkMacApp: App {
    @StateObject private var runtime = EdgeLinkRuntime()
    @State private var smsRecipient = ""
    @State private var smsText = ""

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

                VStack(alignment: .leading, spacing: 8) {
                    Text("SMS")
                        .font(.subheadline)
                    TextField("Recipient", text: $smsRecipient)
                        .textFieldStyle(.roundedBorder)
                    TextField("Message", text: $smsText)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        runtime.sendSms(to: smsRecipient, text: smsText)
                        smsText = ""
                    } label: {
                        Label("Send SMS", systemImage: "paperplane")
                    }
                    .disabled(
                        !runtime.isConnected ||
                            smsRecipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            smsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                    if !runtime.smsSendStatus.isEmpty {
                        Text(runtime.smsSendStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !runtime.smsMessages.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(runtime.smsMessages.prefix(5))) { message in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(message.direction == "outbound" ? "To \(message.address)" : "From \(message.address)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(message.text)
                                        .font(.caption)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }

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
            .frame(width: 320)
        }
        .menuBarExtraStyle(.window)
    }
}
