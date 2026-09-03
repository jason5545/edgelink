import Foundation

// Drives the phone's MirrorCallService PHONERELAY machinery (the call-audio
// RTSP/RTP source on phone:7102 and the sink pulling the Mac's advertised
// endpoint, armed only by SimpleEventMessage events 23/24/31/25 on the cast
// trust channel) from EdgeLink's own phone.call_status reporting — that
// reporting arrives on every transport, while the TeleService
// update_call_state back-channel that used to drive this is dead on phones
// that filter the Mac's deviceType out of the relay service map
// (RelayServiceFilterUtils; live 2026-09-02).
//
// A phone call without an active mirror has no cast channel, so the driver
// also ensures the channel-only trust session exists while a call is
// ongoing, and re-dials it when the phone releases it mid-call.
//
// The drives are state-based, not exactly-once: the closures write
// LyraMirrorCallRelaySession's pending state (pendingCallActive /
// preferRelayAdvertise), which a session built AFTER the drive applies in
// start() — firing into a nil activeSession used to drop the whole call's
// audio (live 2026-09-02).
@MainActor
final class MirrorCallTriggerDriver {
    var hasCastSession: () -> Bool = { false }
    // True only for a session whose channel negotiated at least once and is
    // now released — redialing a fresh mid-dial session aborts the in-flight
    // negotiation (LyraCastTrustSession.channelWasEstablishedBefore).
    var castChannelNeedsRedial: () -> Bool = { false }
    var isMirrorFlowBusy: () -> Bool = { false }
    var ensureChannel: (String) -> Void = { _ in }
    var setCallActive: (Bool) -> Void = { _ in }
    var redialChannel: () -> Void = {}
    var setRelayAdvertiseEndpoint: () -> Void = {}
    var clearPendingState: () -> Void = {}
    var ensureMinInterval: TimeInterval = 3
    var now: () -> Date = Date.init

    private var lastChannelActionAt = Date.distantPast
    private var cloudBridgeEngaged = false

    private static let ongoingStates: Set<String> = ["ringing", "dialing", "connecting", "active", "held"]
    private static let terminalStates: Set<String> = ["disconnected", "disconnecting", "ended", "all"]

    func handleCallStatus(state: String, ongoingCallCount: Int) {
        if Self.ongoingStates.contains(state) {
            if !hasCastSession() {
                ensureChannelThrottled(reason: "call_audio")
            } else if castChannelNeedsRedial() {
                // Mid-call channel release tore the mirror-call relay down
                // with the channel. The session's redialCastChannel fails
                // fast (the in-place redial is never answered — the phone
                // has no key state for the fresh connId, live 2026-09-03),
                // and handleSessionFinished's ensure rebuilds it.
                redialChannelThrottled()
            }
        }
        if state == "active" {
            // Forwarded on every active status (details_changed repeats
            // them): the closure writes the pending state a late-built
            // session applies, and the session dedupes no-change drives.
            setCallActive(true)
        }
        if Self.terminalStates.contains(state), ongoingCallCount == 0 {
            // stopPhoneCallRelayAudio (which resets this driver) runs inside
            // handlePhoneCallStatus BEFORE the driver's terminal call, so
            // the stop drive must reach the session even when this call
            // never went active here — LyraMirrorCallRelaySession dedupes a
            // stop for a call that never started.
            setCallActive(false)
        }
    }

    // The phone released the cast channel mid-call (e.g. MirrorCallService
    // idle teardown). The mirror flow restarts itself on release, so never
    // double-redial while it is busy.
    func handleChannelReleased(callOngoing: Bool) {
        guard callOngoing, !isMirrorFlowBusy() else { return }
        if hasCastSession() {
            redialChannel()
        } else {
            ensureChannelThrottled(reason: "call_audio_released")
        }
    }

    // The cast trust session finished (e.g. the fail-fast redial after a
    // mid-call release — the phone never answers an in-place redialed logi
    // request on a fresh connId, live 2026-09-03). Only a fresh session
    // gets the channel back. This hook exists because phone.call_status is
    // NOT a reliable heartbeat: the per-second details_changed stream stops
    // once the call is stably active, so without it a mid-call channel
    // death is never recovered (live 2026-09-03: redial stall at active+5s,
    // then silence — no further statuses, no ensure, no audio for the rest
    // of the call). The ensure must NOT ride the throttle: a fail-fast
    // redial just consumed lastChannelActionAt fractions of a second ago,
    // and throttling here reintroduces a multi-second audio stall.
    func handleSessionFinished(callOngoing: Bool) {
        guard callOngoing, !isMirrorFlowBusy() else { return }
        guard !hasCastSession() else { return }
        lastChannelActionAt = now()
        ensureChannel("call_audio_session_finished")
    }

    // The Android cloud bridge's phone-local RTSP sink server is up: the
    // Mac mic uplink reaches the phone's MirrorCallService sink through
    // it, so the mirror-call KeyData must advertise that endpoint.
    func handleCloudBridgeEngaged() {
        guard !cloudBridgeEngaged else { return }
        cloudBridgeEngaged = true
        setRelayAdvertiseEndpoint()
        DiagnosticsLog.info("xiaomi.mirrorcall.advertise_relay")
    }

    func reset() {
        lastChannelActionAt = .distantPast
        cloudBridgeEngaged = false
        clearPendingState()
    }

    private func ensureChannelThrottled(reason: String) {
        let timestamp = now()
        guard timestamp.timeIntervalSince(lastChannelActionAt) >= ensureMinInterval else { return }
        lastChannelActionAt = timestamp
        ensureChannel(reason)
    }

    private func redialChannelThrottled() {
        let timestamp = now()
        guard timestamp.timeIntervalSince(lastChannelActionAt) >= ensureMinInterval else { return }
        lastChannelActionAt = timestamp
        redialChannel()
    }
}
