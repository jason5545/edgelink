import AppKit
import EdgeLinkKit
import SwiftUI

@MainActor
private final class EdgeLinkAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        EdgeLinkURLRouter.shared.open(urls)
    }
}

@main
struct EdgeLinkMacApp: App {
    @NSApplicationDelegateAdaptor(EdgeLinkAppDelegate.self) private var appDelegate
    @StateObject private var runtime = EdgeLinkRuntime()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(runtime: runtime)
        } label: {
            Image("MenuBarIcon")
                .accessibilityLabel("EdgeLink")
        }
        .menuBarExtraStyle(.window)

        Window("訊息", id: "sms") {
            MessagesWindow(runtime: runtime)
                .background(WindowFrameAutosaver(name: "EdgeLinkMessagesWindow"))
        }
        .defaultSize(width: 360, height: 480)

        Window("剪貼簿歷史", id: "clipboard") {
            ClipboardHistoryWindow(runtime: runtime)
                .background(WindowFrameAutosaver(name: "EdgeLinkClipboardWindow"))
        }
        .defaultSize(width: 400, height: 480)
    }
}

private enum MenuBarSection: String, CaseIterable, Identifiable {
    case status
    case phone
    case tunnel
    case miShare
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status:
            return String(localized: "狀態")
        case .phone:
            return String(localized: "手機")
        case .tunnel:
            return String(localized: "隧道")
        case .miShare:
            return String(localized: "快傳")
        case .settings:
            return String(localized: "設定")
        }
    }
}

private struct MenuBarPopover: View {
    @ObservedObject var runtime: EdgeLinkRuntime
    @Environment(\.openWindow) private var openWindow
    @State private var selectedSection: MenuBarSection = .status

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if runtime.isPairing {
                PairingPanel(runtime: runtime)
            } else {
                Picker("分類", selection: $selectedSection) {
                    ForEach(MenuBarSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                switch selectedSection {
                case .status:
                    StatusSection(runtime: runtime)
                case .phone:
                    PhoneSection(runtime: runtime, openWindow: openWindow)
                case .tunnel:
                    TunnelSection(runtime: runtime)
                case .miShare:
                    MiShareSection(runtime: runtime)
                case .settings:
                    SettingsSection(runtime: runtime)
                }

                Divider()

                HStack {
                    Button {
                        runtime.startPairing()
                    } label: {
                        Label("配對新裝置", systemImage: "plus.circle")
                    }

                    Spacer()

                    Button(role: .destructive) {
                        runtime.quit()
                    } label: {
                        Label("結束 EdgeLink", systemImage: "power")
                    }
                }
            }
        }
        .padding()
        .frame(width: 300)
    }
}

private struct StatusSection: View {
    @ObservedObject var runtime: EdgeLinkRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusSummary(runtime: runtime)

            if !runtime.peerDeviceId.isEmpty {
                Divider()
                ConnectionActions(runtime: runtime)
            }

            if runtime.latestVerificationCode != nil {
                Divider()
                LatestVerificationCodePanel(runtime: runtime)
            }
        }
    }
}

private struct PhoneSection: View {
    @ObservedObject var runtime: EdgeLinkRuntime
    let openWindow: OpenWindowAction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !runtime.peerDeviceId.isEmpty {
                PhoneControlPanel(runtime: runtime)
                Divider()
            }

            if runtime.isPhoneScreenSessionActive {
                Button {
                    runtime.showPhoneScreen()
                } label: {
                    Label(
                        runtime.isPhoneScreenViewerVisible ? "重新檢視" : "重新檢視手機畫面",
                        systemImage: "rectangle.on.rectangle"
                    )
                }

                Button {
                    runtime.stopPhoneScreen()
                } label: {
                    Label("停止手機投放", systemImage: "stop.circle")
                }
                .accessibilityLabel("stopPhoneScreen")
            } else {
                Button {
                    runtime.viewPhoneScreen()
                } label: {
                    Label(
                        runtime.hasViewedPhoneScreen ? "重新檢視" : "檢視手機畫面",
                        systemImage: "iphone"
                    )
                }
                .disabled(!runtime.isConnected)
                .accessibilityLabel("viewPhoneScreen")
            }

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "sms")
            } label: {
                Label("訊息…", systemImage: "message")
            }

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "clipboard")
            } label: {
                Label("剪貼簿歷史…", systemImage: "list.clipboard")
            }

            switch runtime.xiaomiTrustPairing {
            case .paired:
                Label("已配對（小米互聯）", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            case .unpaired:
                Label("未配對（小米互聯）", systemImage: "xmark.shield")
                    .foregroundStyle(.secondary)
            case .unknown:
                Label("小米互聯配對狀態未知", systemImage: "questionmark.shield")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MiShareSection: View {
    @ObservedObject var runtime: EdgeLinkRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            XiaomiMiShareDiscoveryPanel(runtime: runtime)

            Button {
                runtime.sendFilesWithXiaomiHyperConnect()
            } label: {
                Label("小米快傳傳檔給手機", systemImage: "paperplane")
            }

            if !runtime.xiaomiMiLinkCommandStatus.isEmpty {
                Text(runtime.xiaomiMiLinkCommandStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct TunnelSection: View {
    @ObservedObject var runtime: EdgeLinkRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                runtime.enableAdbTunnel()
            } label: {
                Label("啟用 ADB 隧道", systemImage: "terminal")
            }
            .disabled(!runtime.isConnected)

            if let adbPort = runtime.tunnelAdbPort {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("adb connect localhost:\(String(adbPort))")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if !runtime.tunnelStatusText.isEmpty {
                Text(runtime.tunnelStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if runtime.tunnelAdbPort != nil {
                Divider()
                Button(role: .destructive) {
                    runtime.disableAdbTunnel()
                } label: {
                    Label("停止 ADB 隧道", systemImage: "stop.circle")
                }
            }
        }
    }
}

private struct SettingsSection: View {
    @ObservedObject var runtime: EdgeLinkRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Mac 通知",
                isOn: Binding(
                    get: { runtime.macNotificationSyncEnabled },
                    set: { runtime.setMacNotificationSyncEnabled($0) }
                )
            )
            .toggleStyle(.switch)

            Toggle(
                "系統驗證碼",
                isOn: Binding(
                    get: { runtime.verificationCodeSystemBridgeEnabled },
                    set: { runtime.setVerificationCodeSystemBridgeEnabled($0) }
                )
            )
            .toggleStyle(.switch)

            Toggle(
                "通話回音消除",
                isOn: Binding(
                    get: { runtime.phoneRelayEchoCancellationEnabled },
                    set: { runtime.setPhoneRelayEchoCancellationEnabled($0) }
                )
            )
            .toggleStyle(.switch)

            Toggle(
                "自動複製驗證碼",
                isOn: Binding(
                    get: { runtime.verificationCodeAutoCopyEnabled },
                    set: { runtime.setVerificationCodeAutoCopyEnabled($0) }
                )
            )
            .toggleStyle(.switch)

            Toggle(
                "照片同步到圖庫",
                isOn: Binding(
                    get: { runtime.photoSyncEnabled },
                    set: { runtime.setPhotoSyncEnabled($0) }
                )
            )
            .toggleStyle(.switch)

            if runtime.photoSyncEnabled, !runtime.photoSyncStatus.isEmpty {
                Text(runtime.photoSyncStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct XiaomiMiShareDiscoveryPanel: View {
    @ObservedObject var runtime: EdgeLinkRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(runtime.xiaomiMiShareDiscoveryStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if !runtime.xiaomiMiShareDiscoveredPeers.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(runtime.xiaomiMiShareDiscoveredPeers.prefix(3)) { peer in
                        Text(miSharePeerLine(peer))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Button {
                runtime.restartXiaomiMiShareDiscovery()
            } label: {
                Label("重新掃描小米快傳", systemImage: "dot.radiowaves.left.and.right")
            }
        }
    }

    private func miSharePeerLine(_ peer: XiaomiMiShareDiscoveredPeer) -> String {
        let deviceId = peer.deviceIdHex.map { " \($0)" } ?? ""
        let channel = peer.channel.map { " CH=\($0)" } ?? ""
        return String(localized: "手機 \(peer.displayLabel)\(deviceId)\(channel)")
    }
}

private struct LatestVerificationCodePanel: View {
    @ObservedObject var runtime: EdgeLinkRuntime

    var body: some View {
        if let candidate = runtime.latestVerificationCode {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayCode)
                        .font(.system(.title3, design: .monospaced))
                        .lineLimit(1)
                    Text(candidate.sourceAddress ?? String(localized: "驗證碼"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    runtime.copyLatestVerificationCode()
                } label: {
                    Label("複製", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .help("複製驗證碼")
            }
        }
    }
}

private struct StatusSummary: View {
    @ObservedObject var runtime: EdgeLinkRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("EdgeLink")
                .font(.headline)
            Text(localizedConnectionStatus(runtime.connectionStatus))
                .font(.subheadline)
            Text(runtime.peerDeviceId.isEmpty ? String(localized: "尚未配對 Android") : runtime.peerName)
                .lineLimit(1)
            Text("本機 \(runtime.localDeviceId)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !runtime.peerDeviceId.isEmpty {
                Text("Peer \(runtime.peerDeviceId)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let miLinkSummary = xiaomiMiLinkSummary(runtime.latestMiLinkStatus) {
                Text(miLinkSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            PhoneBatteryRow(runtime: runtime)
        }
    }
}

private struct PhoneBatteryRow: View {
    @ObservedObject var runtime: EdgeLinkRuntime

    private var batteryIcon: String {
        guard let level = runtime.phoneBatteryLevel else { return "battery.0" }
        switch level {
        case 75...: return "battery.100"
        case 50..<75: return "battery.75"
        case 25..<50: return "battery.50"
        default: return "battery.25"
        }
    }

    private var isLowBattery: Bool {
        guard let level = runtime.phoneBatteryLevel else { return false }
        return level <= 20
    }

    var body: some View {
        if let level = runtime.phoneBatteryLevel {
            HStack(spacing: 4) {
                Image(systemName: batteryIcon)
                    .foregroundStyle(isLowBattery ? .red : .primary)
                Text("\(level)%")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(isLowBattery ? .red : .primary)
                if runtime.phoneBatteryCharging {
                    Image(systemName: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if isLowBattery {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                if !runtime.phoneBatterySource.isEmpty {
                    Text(runtime.phoneBatterySource)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "battery.0")
                    .foregroundStyle(.secondary)
                Text("—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConnectionActions: View {
    @ObservedObject var runtime: EdgeLinkRuntime

    var body: some View {
        HStack {
            Button {
                runtime.reconnect()
            } label: {
                Label("重新連線", systemImage: "arrow.clockwise")
            }

            Button {
                runtime.disconnect()
            } label: {
                Label("中斷", systemImage: "xmark.circle")
            }
            .disabled(!runtime.canDisconnect)
        }
    }
}

/// 通話中即時送鍵的本機按鍵監聽：面板開著且通話中時，0-9 / * / # 按下即送單一
/// DTMF tone 並吞掉事件（不進輸入欄、不觸發輸入法組字——實測 Rime/注音 會把
/// 輸入欄焦點下的數字鍵組成 ㄓ，見 2026-09-03 實測）；Cmd+V 貼上、Esc、Tab 等
/// 其餘按鍵原樣放行。local monitor 只作用於本 app；popover 關閉即 stop。
private final class LiveDTMFKeyMonitor {
    private static let toneCharacters: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "#"]

    private var monitor: Any?

    /// 重複呼叫安全：已有 monitor 在跑就直接略過。
    func start(onTone: @escaping (String) -> Void) {
        guard monitor == nil else {
            return
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let tone = Self.dtmfTone(for: event) else {
                return event
            }
            onTone(tone)
            return nil
        }
        DiagnosticsLog.info("phone.mac.live_dtmf_monitor_start")
    }

    /// 重複呼叫安全。
    func stop() {
        guard let monitor else {
            return
        }
        self.monitor = nil
        NSEvent.removeMonitor(monitor)
        DiagnosticsLog.info("phone.mac.live_dtmf_monitor_stop")
    }

    /// 單一 DTMF 字元才回傳；`*` 可能來自 Shift+8 或數字鍵盤、`#` 來自 Shift+3，
    /// 所以用套用 shift 後的 `characters` 判定。Shift / numericPad / function
    /// 之外的 modifier（Cmd、Option…）一律放行給系統。
    private static func dtmfTone(for event: NSEvent) -> String? {
        guard event.modifierFlags.subtracting([.shift, .numericPad, .function]).isEmpty else {
            return nil
        }
        guard let characters = event.characters ?? event.charactersIgnoringModifiers,
              characters.count == 1,
              let character = characters.first,
              toneCharacters.contains(character)
        else {
            return nil
        }
        return String(character)
    }

    deinit {
        stop()
    }
}

private struct PhoneControlPanel: View {
    @ObservedObject var runtime: EdgeLinkRuntime
    @State private var phoneNumber = ""
    /// 本次通話最近送出的 DTMF tone（最多保留 16 個），通話開始/結束時清空。
    @State private var sentToneTrail = ""
    /// 焦點只為貼上方便；單鍵送出靠 dtmfKeyMonitor，不依賴焦點或輸入法狀態。
    @FocusState private var phoneFieldFocused: Bool
    @State private var dtmfKeyMonitor = LiveDTMFKeyMonitor()

    private var trimmedPhoneNumber: String {
        phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitPhoneInput() {
        // 通話中單鍵由 dtmfKeyMonitor 即時送出、貼上由 onChange 整段送出，
        // Enter 不需做任何事。
        guard !runtime.isPhoneCallActive else {
            return
        }
        if runtime.dialPhone(number: trimmedPhoneNumber) != nil {
            phoneNumber = ""
        }
    }

    private func sendLiveDTMF(_ sequence: String) {
        guard runtime.isPhoneCallActive else {
            return
        }
        if runtime.sendPhoneDTMF(sequence: sequence) != nil {
            sentToneTrail.append(contentsOf: sequence)
            if sentToneTrail.count > 16 {
                sentToneTrail = String(sentToneTrail.suffix(16))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(runtime.isPhoneCallActive ? "客服按鍵" : "電話號碼", text: $phoneNumber)
                    .textFieldStyle(.roundedBorder)
                    .focused($phoneFieldFocused)
                    .onSubmit {
                        submitPhoneInput()
                    }

                if !runtime.isPhoneCallActive {
                    Button {
                        submitPhoneInput()
                    } label: {
                        Label("撥號", systemImage: "phone.arrow.up.right")
                    }
                    .disabled(!runtime.isConnected || trimmedPhoneNumber.isEmpty)

                    Button {
                        if runtime.redialLastPhoneNumber() != nil {
                            phoneNumber = ""
                        }
                    } label: {
                        Label("重撥", systemImage: "phone.arrow.up.right.circle")
                    }
                    .disabled(!runtime.isConnected || runtime.lastDialedPhoneNumber.isEmpty)
                    .help("重撥上一個由 EdgeLink 撥出的號碼")
                }
            }

            HStack(spacing: 8) {
                Button(role: .destructive) {
                    runtime.hangUpPhoneCall()
                } label: {
                    Label("掛斷", systemImage: "phone.down")
                }
                .disabled(!runtime.isConnected)
            }

            if runtime.isPhoneCallActive && !sentToneTrail.isEmpty {
                Text("已送：\(sentToneTrail)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("本次通話最近送出的按鍵（最多保留 16 個）")
            }

            if !runtime.phoneCallStatus.isEmpty {
                Text(runtime.phoneCallStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .onAppear {
            if runtime.isPhoneCallActive {
                dtmfKeyMonitor.start(onTone: sendLiveDTMF)
                phoneFieldFocused = true
            } else if phoneNumber.isEmpty {
                phoneNumber = runtime.lastDialedPhoneNumber
            }
        }
        .onDisappear {
            dtmfKeyMonitor.stop()
        }
        .onChange(of: phoneNumber) { previous, current in
            // 通話中只剩貼上會進到這裡（單鍵已被 monitor 吞掉）；delta 非法
            // （刪除、取代、非法字元）時直接清空，不讓殘字影響下一次 delta。
            guard runtime.isPhoneCallActive else {
                return
            }
            guard let sequence = LiveDTMF.liveDTMFDelta(previous: previous, current: current) else {
                if !current.isEmpty {
                    phoneNumber = ""
                }
                return
            }
            sendLiveDTMF(sequence)
            phoneNumber = ""
        }
        .onChange(of: runtime.isPhoneCallActive) { isActive in
            sentToneTrail = ""
            if isActive {
                dtmfKeyMonitor.start(onTone: sendLiveDTMF)
                if phoneNumber == runtime.lastDialedPhoneNumber {
                    phoneNumber = ""
                }
                phoneFieldFocused = true
            } else {
                dtmfKeyMonitor.stop()
            }
        }
    }
}

private struct PairingPanel: View {
    @ObservedObject var runtime: EdgeLinkRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("配對 EdgeLink")
                .font(.headline)
            Text("本機 ID \(runtime.localDeviceId)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(localizedPairingStatus(runtime.pairingStatus))
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
    }
}

private struct MessagesWindow: View {
    @ObservedObject var runtime: EdgeLinkRuntime
    @State private var smsRecipient = ""
    @State private var smsText = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(runtime.smsMessages) { message in
                        MessageRow(message: message)
                    }

                    if runtime.smsMessages.isEmpty {
                        Text("還沒有訊息")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                TextField("收件人", text: $smsRecipient)
                    .textFieldStyle(.roundedBorder)
                TextField("訊息", text: $smsText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    if !runtime.smsSendStatus.isEmpty {
                        Text(runtime.smsSendStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        runtime.sendSms(to: smsRecipient, text: smsText)
                        smsText = ""
                    } label: {
                        Label("送出", systemImage: "paperplane")
                    }
                    .disabled(
                        !runtime.isConnected ||
                            smsRecipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            smsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .padding()
        }
        .frame(minWidth: 320, minHeight: 420)
    }
}

private struct MessageRow: View {
    let message: SmsMessageBody

    private var isOutbound: Bool {
        message.direction == "outbound"
    }

    var body: some View {
        HStack {
            if isOutbound {
                Spacer(minLength: 36)
            }

            VStack(alignment: isOutbound ? .trailing : .leading, spacing: 4) {
                Text(isOutbound ? "傳給 \(message.address)" : "來自 \(message.address)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.quaternary)
                    )

                Text(Date(timeIntervalSince1970: TimeInterval(message.ts)), style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !isOutbound {
                Spacer(minLength: 36)
            }
        }
    }
}

private struct WindowFrameAutosaver: NSViewRepresentable {
    let name: NSWindow.FrameAutosaveName

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.setFrameAutosaveName(name)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.setFrameAutosaveName(name)
        }
    }
}

private func localizedConnectionStatus(_ status: String) -> String {
    switch status {
    case "Starting":
        return String(localized: "啟動中")
    case "Registering":
        return String(localized: "註冊裝置中")
    case "No paired Android":
        return String(localized: "尚未配對 Android")
    case "Setup failed":
        return String(localized: "初始化失敗")
    case "Reconnecting":
        return String(localized: "重新連線中")
    case "Connecting relay":
        return String(localized: "連線到 relay")
    case "Handshaking":
        return String(localized: "握手中")
    case "Connected":
        return String(localized: "已連線")
    case "Disconnected":
        return String(localized: "已中斷")
    default:
        return status
    }
}

private func localizedPairingStatus(_ status: String) -> String {
    switch status {
    case "Registering":
        return String(localized: "註冊裝置中")
    case "Opening pairing":
        return String(localized: "正在開啟配對")
    case "Compare code":
        return String(localized: "確認兩邊數字相同")
    case "Waiting for Android":
        return String(localized: "等待 Android 確認")
    case "Pairing failed":
        return String(localized: "配對失敗")
    case "Paired":
        return String(localized: "已配對")
    default:
        return status
    }
}

private func xiaomiMiLinkSummary(_ status: MiLinkStatusBody?) -> String? {
    guard let status else {
        return nil
    }
    let services = status.services ?? []
    let available = services.filter(\.available)
    guard status.available || !available.isEmpty else {
        return String(localized: "Mi 優先：未就緒")
    }

    let names = available
        .filter(\.preferred)
        .map { service in
            switch service.category {
            case "fileTransfer":
                return String(localized: "快傳")
            case "screen":
                return service.serviceName == "synergy" ? String(localized: "妙享") : String(localized: "鏡像")
            case "recentApps":
                return "RecentApps"
            case "audio":
                return String(localized: "音訊")
            default:
                return service.serviceName
            }
        }
    let uniqueNames = Array(NSOrderedSet(array: names)) as? [String] ?? names
    if uniqueNames.isEmpty {
        return String(localized: "Mi 優先：探測中")
    }
    let joinedNames = uniqueNames.joined(separator: " / ")
    return String(localized: "Mi 優先：\(joinedNames)")
}
