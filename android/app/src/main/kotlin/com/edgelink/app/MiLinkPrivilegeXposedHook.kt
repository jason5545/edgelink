package com.edgelink.app

import android.content.Context
import android.content.ContentProvider
import android.content.Intent
import android.media.AudioRecord
import android.media.AudioTrack
import android.os.Binder
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import kotlin.concurrent.thread
import io.github.libxposed.api.XposedInterface
import java.lang.reflect.Executable
import java.lang.reflect.Method
import java.util.ArrayList
import java.util.Collections
import java.util.HashMap

internal object MiLinkPrivilegeHookPolicy {
    const val EDGE_LINK_PACKAGE = "com.edgelink.app"
    const val ANDROID_PACKAGE = "android"
    const val MILINK_PACKAGE = "com.milink.service"
    const val MILINK_MAIN_PROCESS = "com.milink.service"
    const val MILINK_RUNTIME_PROCESS = "com.milink.runtime"
    const val XIAOMI_MIRROR_PACKAGE = "com.xiaomi.mirror"
    const val XIAOMI_MIRROR_PROCESS = "com.xiaomi.mirror"
    const val XIAOMI_MISHARE_PACKAGE = "com.miui.mishare.connectivity"
    const val IN_CALL_UI_PACKAGE = "com.android.incallui"
    const val TELEPHONY_PACKAGE = "com.android.phone"
    const val AUDIO_MONITOR_PACKAGE = "com.miui.audiomonitor"
    const val SYSTEM_SERVER_PROCESS = "system_server"
    const val SYSTEM_PROCESS = "system"
    const val XIAOMI_MIRROR_CAST_FRAME_ACTION = "com.edgelink.app.XIAOMI_MIRROR_CAST_FRAME"
    const val XIAOMI_MIRROR_CAST_FRAME_EXTRA = "frame"
    const val FAKE_MIRROR_REMOTE_ID = "edgelink-mac-mi-pad"

    // DistAudio uplink direct-feed listener port (audiomonitor hook). The
    // Mac side (LyraDistAudioUplink.directFeedPort) must carry the same
    // value — pinned by tests on both sides.
    const val DIST_AUDIO_DIRECT_FEED_PORT = 45671

    // One feed datagram = one 20ms 16kHz mono PCM frame encrypted as
    // AES-128-ECB/PKCS7 (640B PCM → 656B cipher). Anything else landing on
    // the port is the Mac's phys-sync sweep (141-byte Lyra mesh frames
    // among others) and must be dropped.
    fun isDistAudioFeedFrameSize(length: Int): Boolean = length >= 16 && length % 16 == 0

    private val mirrorPhoneProviderMethods = setOf(
        "getAliveBinder",
        "queryRemoteDevices",
        "queryRemoteDevice",
        "openRemoteDeviceMirror",
        "openRemoteDeviceMirrorByBtMac",
        "performMirrorDeviceIconClick",
        "startRemoteMainMirrorDisplay",
        "isSynergyEnable",
        "isRelayEnable",
        "showRelayData",
        "syncRelayData",
        "cancelRelayData",
        "getCallRelayService",
        "registerMediaRelayCallback",
        "unregisterMediaRelayCallback",
        "startMediaRelay",
        "stopMediaRelay",
        "setMediaRelayVolume",
        "edgeLinkCastChannel"
    )

    fun shouldHook(packageName: String?, processName: String?): Boolean =
        shouldHookRuntime(packageName, processName) ||
            shouldHookMainService(packageName, processName) ||
            shouldHookXiaomiMirror(packageName, processName) ||
            shouldHookAndroidSystem(packageName, processName) ||
            shouldHookMiShare(packageName, processName) ||
            shouldHookInCallUI(packageName) ||
            shouldHookTeleService(packageName) ||
            shouldHookAudioMonitor(packageName)

    fun shouldHookAudioMonitor(packageName: String?): Boolean =
        packageName == AUDIO_MONITOR_PACKAGE

    fun shouldHookInCallUI(packageName: String?): Boolean =
        packageName == IN_CALL_UI_PACKAGE

    fun shouldHookTeleService(packageName: String?): Boolean =
        packageName == TELEPHONY_PACKAGE

    fun shouldHookMiShare(packageName: String?, processName: String?): Boolean =
        packageName == XIAOMI_MISHARE_PACKAGE

    fun shouldHookRuntime(packageName: String?, processName: String?): Boolean =
        packageName == MILINK_PACKAGE && processName == MILINK_RUNTIME_PROCESS

    fun shouldHookMainService(packageName: String?, processName: String?): Boolean =
        packageName == MILINK_PACKAGE && processName == MILINK_MAIN_PROCESS

    fun shouldHookXiaomiMirror(packageName: String?, processName: String?): Boolean =
        packageName == XIAOMI_MIRROR_PACKAGE && processName == XIAOMI_MIRROR_PROCESS

    fun shouldHookAndroidSystem(packageName: String?, processName: String?): Boolean =
        packageName == ANDROID_PACKAGE &&
            (processName == null ||
                processName == ANDROID_PACKAGE ||
                processName == SYSTEM_SERVER_PROCESS ||
                processName == SYSTEM_PROCESS)

    fun isAllowedCallerPackage(packageName: String?): Boolean =
        packageName == EDGE_LINK_PACKAGE

    fun hasAllowedCallerPackage(packages: Array<String>?): Boolean =
        packages?.any(::isAllowedCallerPackage) == true

    fun isAllowedMirrorPhoneProviderMethod(method: String?): Boolean =
        method in mirrorPhoneProviderMethods

    fun isFakeMirrorRemoteId(deviceId: String?): Boolean =
        deviceId == FAKE_MIRROR_REMOTE_ID
}

class MiLinkPrivilegeXposedHook(private val xposed: XposedInterface) {
    private val installedTargets = Collections.synchronizedList(mutableListOf<InstalledTarget>())

    data class InstalledTarget(
        val packageName: String?,
        val processName: String?,
        val classLoader: ClassLoader,
        val systemServer: Boolean
    )

    fun buildSavedState(): ArrayList<HashMap<String, Any?>> =
        ArrayList(
            synchronized(installedTargets) {
                installedTargets.map { target ->
                    hashMapOf<String, Any?>(
                        "packageName" to target.packageName,
                        "processName" to target.processName,
                        "classLoader" to target.classLoader,
                        "systemServer" to target.systemServer
                    )
                }
            }
        )

    fun shutdown() {
        runCatching { MiShareTrustInjection.shutdown() }
        log("generation shutdown complete")
    }

    fun installForPackage(
        packageName: String?,
        processName: String?,
        classLoader: ClassLoader,
        systemServer: Boolean
    ) {
        if (!MiLinkPrivilegeHookPolicy.shouldHook(packageName, processName)) {
            return
        }

        installedTargets += InstalledTarget(packageName, processName, classLoader, systemServer)
        log("loading hooks in package=$packageName process=$processName")
        if (MiLinkPrivilegeHookPolicy.shouldHookRuntime(packageName, processName)) {
            hookRuntimeCallingPackageCheck(classLoader)
            hookRuntimeCallingUidCheck(classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookMainService(packageName, processName)) {
            hookCastClientServiceCheck(classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookXiaomiMirror(packageName, processName)) {
            hookMirrorCallProviderAccessCheck(classLoader)
            hookMirrorWifiOpenGate(classLoader)
            hookMirrorDeviceManagerAdmit(classLoader)
            hookMirrorUnlockIslandGate(classLoader)
            installMirrorCastChannelTracker(classLoader)
            hookMirrorOfficialScreenConfiguration(classLoader)
            hookMirrorSourceRecoveryProvider(classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookAndroidSystem(packageName, processName)) {
            hookXiaomiMirrorSystemPackageGids(classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookMiShare(packageName, processName)) {
            hookMiShareLyraTrustInjection(classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookInCallUI(packageName)) {
            hookInCallUiDistAudioTypeFilter(classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookTeleService(packageName)) {
            hookTeleServiceRelayAudioConnect(classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookAudioMonitor(packageName)) {
            hookAudioMonitorDistRpcRetry(classLoader)
            hookAudioMonitorStreamStop(classLoader)
            hookAudioMonitorStreamReconnect(classLoader)
            hookAudioMonitorDirectUplinkFeed(classLoader)
        }
    }

    // TeleService never arms mConnectRelayAudio for outgoing relay dials:
    // handleRelayDialRequest calls setDeviceInRelay synchronously right after
    // placeCall, before the relayed Connection exists, so the
    // getLocalConnectionCallRelayed() lookup inside setDeviceInRelay returns
    // null and the flag is never set (PhoneContinuityController.java:1076-
    // 1084). At ACTIVE the gate then logs "connectRelayAudio:false" and the
    // official DistAudioDeviceProvider.connectDistAudioDevice never runs —
    // the call keeps the phone's local mic/speaker (no mute icon) while our
    // MirrorCall media runs in parallel (live 2026-09-06 09:35: deviceInRelay
    // set, distaudio never engaged, earpiece route all call).
    // Re-arm the official flag right before TeleService's ACTIVE-state
    // evaluation so its own delayed connectDistAudioDevice path runs — no
    // behavior change for non-relayed calls or when no device is in relay.
    // Additionally force the TeleService provider's MiAudioManager
    // registration + route enumeration: on international builds with InCallUI
    // installed, isConnectDiscAudio() is false so onRelayStart never registers
    // (live 2026-09-06 10:58: registerMiAudioManager never logged,
    // connectDistAudioDevice silently no-ops on mMiAudioManager == null).
    private fun hookTeleServiceRelayAudioConnect(classLoader: ClassLoader) {
        runCatching {
            val controllerClass = findTargetClass(
                classLoader, "com.android.services.telephony.relay.phonecall.PhoneContinuityController"
            )
            val relayUtilsClass = findTargetClass(
                classLoader, "com.android.services.telephony.relay.phonecall.RelayUtils\$Relay"
            )
            val providerClass = findTargetClass(
                classLoader, "com.android.services.telephony.relay.phonecall.relayaudio.DistAudioDeviceProvider"
            )
            val getProviderInstance = resolveMethod(providerClass, "getInstance")
            val registerMiAudioManager = resolveMethod(providerClass, "registerMiAudioManager")
            val getAllDistAudioRoutes = resolveMethod(providerClass, "getAllDistAudioRoutes")
            val getDistAudioRoutes = resolveMethod(providerClass, "getDistAudioRoutes")
            val isCallRelayed = resolveMethod(
                relayUtilsClass, "isCallRelayed", android.telecom.Connection::class.java
            )
            val isDeviceInRelay = resolveMethod(controllerClass, "isDeviceInRelay")
            val connectFlag = controllerClass.getDeclaredField("mConnectRelayAudio")
            connectFlag.isAccessible = true
            installHook(
                resolveMethod(
                    controllerClass,
                    "onRelayCallStateChanged",
                    android.telecom.Connection::class.java
                )
            ) { chain ->
                runCatching {
                    val connection = chain.args.getOrNull(0) as? android.telecom.Connection
                    val controller = chain.thisObject
                    if (connection != null && controller != null &&
                        isCallRelayed.invoke(null, connection) == true &&
                        isDeviceInRelay.invoke(controller) == true
                    ) {
                        val provider = getProviderInstance.invoke(null)
                        if (provider != null) {
                            registerMiAudioManager.invoke(provider)
                            getAllDistAudioRoutes.invoke(provider)
                            val routes = getDistAudioRoutes.invoke(provider)
                            log("teleservice distaudio routes=" + dumpDistAudioRoutes(routes))
                        }
                        if (connection.state == android.telecom.Connection.STATE_ACTIVE &&
                            connectFlag.getBoolean(controller) == false
                        ) {
                            connectFlag.setBoolean(controller, true)
                            log("re-armed connectRelayAudio for relayed active call")
                        }
                    }
                }
                chain.proceed()
            }
        }.onFailure { error ->
            log("failed to hook teleservice relay audio connect: " +
                "${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun dumpDistAudioRoutes(routes: Any?): String {
        val map = routes as? Map<*, *> ?: return "null"
        if (map.isEmpty()) return "empty"
        return map.keys.joinToString(",") { key ->
            val info = key?.toString() ?: "null"
            info
        }
    }

    // com.miui.audiomonitor DAS drops the openSpeaker/openMicrophone/
    // startSpeakerStream/startMicStream RPCs when the RPC channel to the
    // remote device is not up yet: connectDistAudioDevice →
    // DistRpcClient.setServiceForDevice(deviceId) only maps services already
    // in DeviceToService (filled by onServiceConnected), and every rpc*()
    // reads volatile mRpcInt and silently returns on null — no retry, and
    // the channel itself is only (re)built by the discovery-driven
    // onServiceOnline → bindService path, which can lag the call by tens of
    // seconds or not fire at all (live 2026-09-06 15:28: channel up 2s
    // after connect → RPCs lost; live 2026-09-06 16:28: no channel for the
    // whole 14s call, stash TTL 30s expired 3s before the channel came up →
    // phone muted itself, Mac got nothing). Stash all four dropped calls
    // and replay them when the service appears — onServiceConnected, a
    // successful setServiceForDevice, or the 1s retry loop reattaching
    // mRpcInt from DeviceToService; the loop also force-reruns bindService()
    // from the cached TrustedDeviceInfo every 5s while the discovery path
    // stalls. A fresh rpc*() that can proceed supersedes any stashed call of
    // the same name, so stale ports/keys from a dead call are never replayed
    // into a new one.
    private class PendingDistRpc(
        val method: Method,
        val args: List<Any?>,
        val stashedAtMs: Long
    )

    private fun hookAudioMonitorDistRpcRetry(classLoader: ClassLoader) {
        runCatching {
            val clientClass = findTargetClass(
                classLoader, "com.miui.audiomonitor.distaudio.message.DistRpcClient"
            )
            val hwInfoClass = findTargetClass(
                classLoader, "com.miui.audiomonitor.distaudio.data.DistHardwareInfo"
            )
            val rpcInterfaceClass = findTargetClass(
                classLoader, "com.miui.audiomonitor.distaudio.message.DistRpcInterface"
            )
            val trustedDeviceInfoClass = findTargetClass(
                classLoader, "com.xiaomi.continuity.networking.TrustedDeviceInfo"
            )
            val rpcIntField = clientClass.getDeclaredField("mRpcInt").apply { isAccessible = true }
            val deviceToServiceField =
                clientClass.getDeclaredField("DeviceToService").apply { isAccessible = true }
            val deviceInfoField =
                clientClass.getDeclaredField("mDeviceInfo").apply { isAccessible = true }
            val setServiceForDevice =
                resolveMethod(clientClass, "setServiceForDevice", String::class.java)
            val bindService = resolveMethod(clientClass, "bindService", trustedDeviceInfoClass)
            val rpcMethods = listOf(
                resolveMethod(
                    clientClass, "rpcOpenSpeaker",
                    String::class.java, hwInfoClass,
                    Boolean::class.javaPrimitiveType!!, String::class.java,
                    Int::class.javaPrimitiveType!!, String::class.java
                ),
                resolveMethod(
                    clientClass, "rpcOpenMicrophone",
                    String::class.java, hwInfoClass, Boolean::class.javaPrimitiveType!!
                ),
                resolveMethod(clientClass, "rpcStartSpeakerStream", String::class.java),
                resolveMethod(clientClass, "rpcStartMicStream", String::class.java)
            )

            val lock = Any()
            val stashed = mutableListOf<PendingDistRpc>()
            val stashTtlMs = 90_000L
            val maxServiceRetryAttempts = 30
            val mainHandler = Handler(Looper.getMainLooper())

            fun currentRpc(client: Any): Any? = rpcIntField.get(client)
            fun serviceFor(client: Any, deviceId: String): Any? =
                (deviceToServiceField.get(client) as? Map<*, *>)?.get(deviceId)
            fun cachedDevice(client: Any, deviceId: String): Any? =
                (deviceInfoField.get(client) as? Map<*, *>)?.get(deviceId)

            fun drainStash(client: Any, why: String) {
                val replay: List<PendingDistRpc>
                synchronized(lock) {
                    val now = SystemClock.elapsedRealtime()
                    val expired = stashed.filter { now - it.stashedAtMs > stashTtlMs }
                    expired.forEach { log("audiomonitor dist rpc stash expired ${it.method.name}") }
                    stashed.removeAll(expired)
                    replay = stashed.toList()
                    stashed.clear()
                }
                for (pending in replay) {
                    if (currentRpc(client) == null) {
                        synchronized(lock) { stashed.add(pending) }
                        continue
                    }
                    runCatching { pending.method.invoke(client, *pending.args.toTypedArray()) }
                        .onSuccess {
                            log("audiomonitor dist rpc replayed ${pending.method.name} why=$why")
                        }
                        .onFailure { error ->
                            log(
                                "audiomonitor dist rpc replay failed ${pending.method.name}: " +
                                    "${error.javaClass.simpleName}: ${error.message}"
                            )
                        }
                }
            }

            fun scheduleServiceRetry(client: Any, deviceId: String, attempt: Int) {
                if (attempt > maxServiceRetryAttempts) {
                    log("audiomonitor dist rpc retry exhausted device=$deviceId")
                    return
                }
                mainHandler.postDelayed({
                    runCatching {
                        if (currentRpc(client) != null) return@runCatching
                        val service = serviceFor(client, deviceId)
                        if (service != null) {
                            rpcIntField.set(client, service)
                            log(
                                "audiomonitor dist rpc reattached device=$deviceId " +
                                    "attempt=$attempt"
                            )
                            drainStash(client, "reattach")
                        } else {
                            if (attempt % 5 == 0) {
                                val cached = cachedDevice(client, deviceId)
                                log(
                                    "audiomonitor dist rpc retry attempt=$attempt " +
                                        "device=$deviceId cached=${cached != null}"
                                )
                                if (cached != null) {
                                    runCatching { bindService.invoke(client, cached) }
                                }
                            }
                            scheduleServiceRetry(client, deviceId, attempt + 1)
                        }
                    }
                }, 1000)
            }

            installHook(setServiceForDevice) { chain ->
                val result = chain.proceed()
                val client = chain.thisObject
                val deviceId = chain.args.getOrNull(0) as? String
                if (client != null && deviceId != null) {
                    if (currentRpc(client) == null) {
                        log("audiomonitor dist rpc no service yet device=$deviceId")
                        val cached = cachedDevice(client, deviceId)
                        if (cached != null) {
                            log("audiomonitor dist rpc force rebind device=$deviceId")
                            runCatching { bindService.invoke(client, cached) }
                        }
                        scheduleServiceRetry(client, deviceId, 1)
                    } else {
                        drainStash(client, "setServiceForDevice")
                    }
                }
                result
            }

            // Response watchdog: the DAS RPC layer has no retransmit for a
            // request that leaves the phone but never gets answered (live
            // 2026-09-06 18:44: distrpc channel rode the relay-fed cast
            // phys conn while it rebuilt; openMicrophone went out between
            // two delivered RPCs and was never answered → no
            // postOpenMicrophone → no startMicStream → uplink dead for the
            // whole call while downlink played fine). Re-send an open* RPC
            // with no postOpen* response within 4s, up to 3 resends;
            // duplicate open* is idempotent on the remote side (healthy
            // calls already receive it twice from the dual providers).
            val distAudioObjectClass = findTargetClass(
                classLoader, "com.miui.audiomonitor.distaudio.message.DistAudioObject"
            )
            val audioManagerClass = findTargetClass(
                classLoader, "com.miui.audiomonitor.distaudio.service.IDistAudioManager"
            )
            val openResponsePost = mapOf(
                "rpcOpenSpeaker" to "postOpenSpeaker",
                "rpcOpenMicrophone" to "postOpenMicrophone"
            )
            val lastOpenResponseAtMs = HashMap<String, Long>()
            for ((rpcName, postName) in openResponsePost) {
                installHook(
                    resolveMethod(audioManagerClass, postName, distAudioObjectClass)
                ) { chain ->
                    synchronized(lock) {
                        lastOpenResponseAtMs[rpcName] = SystemClock.elapsedRealtime()
                    }
                    chain.proceed()
                }
            }
            fun armOpenResponseWatchdog(
                client: Any,
                method: Method,
                args: List<Any?>,
                sentAt: Long,
                resend: Int
            ) {
                mainHandler.postDelayed({
                    val answered = synchronized(lock) {
                        (lastOpenResponseAtMs[method.name] ?: 0L) >= sentAt
                    }
                    if (answered || currentRpc(client) == null) {
                        return@postDelayed
                    }
                    if (resend >= 3) {
                        log("audiomonitor dist rpc watchdog exhausted ${method.name}")
                        return@postDelayed
                    }
                    log("audiomonitor dist rpc watchdog resend ${method.name} attempt=$resend")
                    val resentAt = SystemClock.elapsedRealtime()
                    runCatching { method.invoke(client, *args.toTypedArray()) }
                        .onFailure { error ->
                            log(
                                "audiomonitor dist rpc watchdog resend failed " +
                                    "${method.name}: ${error.javaClass.simpleName}: " +
                                    error.message
                            )
                        }
                    armOpenResponseWatchdog(client, method, args, resentAt, resend + 1)
                }, 4000)
            }

            for (method in rpcMethods) {
                installHook(method) { chain ->
                    val client = chain.thisObject
                    if (client == null || currentRpc(client) == null) {
                        synchronized(lock) {
                            stashed.removeAll { it.method.name == method.name }
                            stashed.add(
                                PendingDistRpc(
                                    method, chain.args.toList(), SystemClock.elapsedRealtime()
                                )
                            )
                        }
                        log("audiomonitor dist rpc stashed ${method.name}")
                        null
                    } else {
                        synchronized(lock) {
                            stashed.removeAll { it.method.name == method.name }
                        }
                        val sentAt = SystemClock.elapsedRealtime()
                        val result = chain.proceed()
                        if (method.name in openResponsePost) {
                            armOpenResponseWatchdog(
                                client, method, chain.args.toList(), sentAt, 0
                            )
                        }
                        result
                    }
                }
            }

            installHook(bindService) { chain ->
                val deviceId = runCatching {
                    trustedDeviceInfoClass.getMethod("getDeviceId")
                        .invoke(chain.args.getOrNull(0)) as? String
                }.getOrNull()
                log("audiomonitor dist rpc bindService device=$deviceId")
                chain.proceed()
            }

            installHook(
                resolveMethod(clientClass, "onServiceDisconnect", String::class.java)
            ) { chain ->
                log("audiomonitor dist rpc service disconnected device=${chain.args.getOrNull(0)}")
                chain.proceed()
            }

            installHook(
                resolveMethod(clientClass, "onServiceConnected", rpcInterfaceClass, String::class.java)
            ) { chain ->
                val result = chain.proceed()
                val client = chain.thisObject
                val deviceId = chain.args.getOrNull(1) as? String
                log("audiomonitor dist rpc service connected device=$deviceId")
                if (client != null && deviceId != null && currentRpc(client) == null) {
                    runCatching { setServiceForDevice.invoke(client, deviceId) }
                }
                if (client != null && currentRpc(client) != null) {
                    drainStash(client, "serviceConnected")
                }
                result
            }
        }.onFailure { error ->
            log(
                "failed to hook audiomonitor dist rpc retry: " +
                    "${error.javaClass.simpleName}: ${error.message}"
            )
        }
    }

    // DistAudioStream.stop()/release() take the stream's monitor, but
    // AudioUplinkThread.startRecord() holds that same monitor for its entire
    // read loop — so once the uplink is streaming, stop() blocks forever and
    // the AudioRecord (source=VOICE_DOWNLINK) leaks: every call leaves a
    // zombie capture that keeps reading muted frames after hangup (live
    // 2026-09-06: session 8761 from the 16:23 call still reading at 16:36,
    // MiPlayCastServer "action write don't operate, state:12" write storm),
    // and the next call's fresh AudioRecord gets silence while the zombie
    // holds the source (Mac saw pes flowing with pcmBytes=0 on the 16:29
    // call). Replace stop() with a deadlock-free sequence — set the volatile
    // status fields first so the threads exit, then stop the AudioRecord/
    // AudioTrack directly (their stop() is safe from another thread and
    // unblocks read()/write()) — and run the same sequence before the stock
    // release() so its synchronized block finds the monitor free.
    private fun hookAudioMonitorStreamStop(classLoader: ClassLoader) {
        runCatching {
            val streamClass = findTargetClass(
                classLoader, "com.miui.audiomonitor.distaudio.resource.DistAudioStream"
            )
            val upLinkField =
                streamClass.getDeclaredField("mUpLinkStatus").apply { isAccessible = true }
            val downLinkField =
                streamClass.getDeclaredField("mDownLinkStatus").apply { isAccessible = true }
            val recordField =
                streamClass.getDeclaredField("mAudioRecord").apply { isAccessible = true }
            val trackField =
                streamClass.getDeclaredField("mAudioTrack").apply { isAccessible = true }

            fun safeStop(stream: Any, why: String) {
                upLinkField.setInt(stream, 3)
                downLinkField.setInt(stream, 3)
                val record = recordField.get(stream) as? AudioRecord
                val track = trackField.get(stream) as? AudioTrack
                if (record != null || track != null) {
                    log(
                        "audiomonitor dist stream safe stop why=$why " +
                            "record=${record != null} track=${track != null}"
                    )
                }
                if (record != null) runCatching { record.stop() }
                if (track != null) runCatching { track.stop() }
            }

            installHook(resolveMethod(streamClass, "stop")) { chain ->
                chain.thisObject?.let { safeStop(it, "stop") }
                null
            }
            installHook(resolveMethod(streamClass, "release")) { chain ->
                chain.thisObject?.let { safeStop(it, "release") }
                chain.proceed()
            }
        }.onFailure { error ->
            log(
                "failed to hook audiomonitor dist stream stop: " +
                    "${error.javaClass.simpleName}: ${error.message}"
            )
        }
    }

    // TeleService and InCallUI each run their own connectDistAudioDevice()
    // per call, and every connect unconditionally replaces mDistAudioStream
    // with a fresh DistAudioStream — orphaning the previous one (its threads
    // keep the AudioRecord; stock stop() can never free it, see above). With
    // the stop deadlock fixed, stop+release the orphan before the reconnect
    // proceeds so at most one stream owns the capture source at a time.
    private fun hookAudioMonitorStreamReconnect(classLoader: ClassLoader) {
        runCatching {
            val managerClass = findTargetClass(
                classLoader, "com.miui.audiomonitor.distaudio.service.IDistAudioManager"
            )
            val streamClass = findTargetClass(
                classLoader, "com.miui.audiomonitor.distaudio.resource.DistAudioStream"
            )
            val routeClass = findTargetClass(
                classLoader, "com.miui.audiomonitor.distaudio.data.DistAudioRoute"
            )
            val streamField =
                managerClass.getDeclaredField("mDistAudioStream").apply { isAccessible = true }
            val streamStop = resolveMethod(streamClass, "stop")
            val streamRelease = resolveMethod(streamClass, "release")
            val upLinkField =
                streamClass.getDeclaredField("mUpLinkStatus").apply { isAccessible = true }
            val downLinkField =
                streamClass.getDeclaredField("mDownLinkStatus").apply { isAccessible = true }
            val recordField =
                streamClass.getDeclaredField("mAudioRecord").apply { isAccessible = true }
            val trackField =
                streamClass.getDeclaredField("mAudioTrack").apply { isAccessible = true }
            val startUplink = resolveMethod(streamClass, "startAudioUplinkStream")
            val startDownlink = resolveMethod(streamClass, "startAudioDownlinkStream")
            installHook(
                resolveMethod(managerClass, "connectDistAudioDevice", routeClass)
            ) { chain ->
                val orphan = chain.thisObject?.let {
                    runCatching { streamField.get(it) }.getOrNull()
                }
                val orphanUplinkLive = orphan != null &&
                    runCatching { upLinkField.getInt(orphan) == 1 }.getOrDefault(false)
                val orphanDownlinkLive = orphan != null &&
                    runCatching { downLinkField.getInt(orphan) == 1 }.getOrDefault(false)
                if (orphan != null) {
                    log("audiomonitor dist stream orphan stop+release before reconnect")
                    runCatching { streamStop.invoke(orphan) }
                    runCatching { streamRelease.invoke(orphan) }
                }
                val result = chain.proceed()
                // The replacement stream's stock start chain needs a fresh
                // MiCastServer client connect (onConnected →
                // startAudioUplinkStream) and a startMicStream RPC round-trip
                // (MSG 7 → startAudioDownlinkStream). A mid-call duplicate
                // connect gets neither: the Mac reuses its downlink TCP, and
                // the phone's second connect wave skips startMicStream (live
                // 2026-09-06 19:08: wave 4 was open*/startSpeakerStream only)
                // — so both directions die ~1s in ("ringback, then silence").
                // Restart whichever legs the orphan had live; both start*
                // methods self-guard on status==1 so a later onConnected /
                // MSG 7 on the fresh stream is a harmless no-op.
                if (orphanUplinkLive || orphanDownlinkLive) {
                    val fresh = chain.thisObject?.let {
                        runCatching { streamField.get(it) }.getOrNull()
                    }
                    if (fresh != null && fresh !== orphan) {
                        if (orphanUplinkLive &&
                            runCatching { recordField.get(fresh) }.getOrNull() != null
                        ) {
                            runCatching { startUplink.invoke(fresh) }
                            log("audiomonitor dist stream reconnect restart uplink")
                        }
                        if (orphanDownlinkLive &&
                            runCatching { trackField.get(fresh) }.getOrNull() != null
                        ) {
                            runCatching { startDownlink.invoke(fresh) }
                            log("audiomonitor dist stream reconnect restart downlink")
                        }
                    }
                }
                result
            }
        }.onFailure { error ->
            log(
                "failed to hook audiomonitor dist stream reconnect: " +
                    "${error.javaClass.simpleName}: ${error.message}"
            )
        }
    }

    // The distaudio uplink's last hop is native: the Mac's RTP/TS stream
    // reaches the phone's MiPlayCastClient runtime (audioOnInit/audioOnStart
    // fire), but the runtime never hands decoded frames to the SDK — the
    // shared-memory delivery is gated by IMirrorOption 0x100707
    // (mIsPhoneRelay), whose only writer is Mirror.apk's PHONERELAY sink
    // setup. So DistAudioStream.lstData stays empty, the telephony-pinned
    // AudioTrack starves, and AudioFlinger removes it ~0.5s in ("prepareTracks_l
    // BUFFER TIMEOUT ... in_call_music", live 2026-09-06 17:38:18.871) — the
    // far end hears nothing for the whole call even though the Mac sends
    // cleanly. Bypass the native gap: the Mac sends each encrypted 20ms PCM
    // frame (the exact 656-byte AES-128-ECB/PKCS7 block the stock doPlay()
    // decrypts with ResourceManager.remoteKey) as a raw UDP datagram to port
    // 15570; this listener feeds them straight into the live DistAudioStream
    // via playCastAudioData(), reusing the stock queue/decrypt/track path.
    private fun hookAudioMonitorDirectUplinkFeed(classLoader: ClassLoader) {
        runCatching {
            val managerClass = findTargetClass(
                classLoader, "com.miui.audiomonitor.distaudio.service.IDistAudioManager"
            )
            val streamClass = findTargetClass(
                classLoader, "com.miui.audiomonitor.distaudio.resource.DistAudioStream"
            )
            val instanceField =
                managerClass.getDeclaredField("INSTANCE").apply { isAccessible = true }
            val streamField =
                managerClass.getDeclaredField("mDistAudioStream").apply { isAccessible = true }
            val playCastAudioData = resolveMethod(
                streamClass, "playCastAudioData",
                ByteArray::class.java, Long::class.javaPrimitiveType!!
            )
            thread(name = "edgelink-distaudio-feed", isDaemon = true) {
                runCatching {
                    // No fixed port is ever free of the Mac's phys-sync
                    // sweep (the phone's reported mesh port list rotates
                    // through ephemeral ports, 45671 included — live
                    // 2026-09-06 19:00). The size filter below drops those
                    // 141-byte mesh frames; the only hard requirement is
                    // winning the bind at audiomonitor start.
                    val socket = DatagramSocket(MiLinkPrivilegeHookPolicy.DIST_AUDIO_DIRECT_FEED_PORT)
                    log(
                        "audiomonitor dist uplink feed listening " +
                            "port=${MiLinkPrivilegeHookPolicy.DIST_AUDIO_DIRECT_FEED_PORT}"
                    )
                    val buffer = ByteArray(2048)
                    val packet = DatagramPacket(buffer, buffer.size)
                    var received = 0L
                    var fed = 0L
                    var droppedNoStream = 0L
                    var droppedBadSize = 0L
                    var badSizeLogged = 0
                    var lastStreamId = 0
                    fun hexHead(data: ByteArray, count: Int): String =
                        data.take(count).joinToString("") { "%02x".format(it) }
                    while (true) {
                        socket.receive(packet)
                        received += 1
                        val length = packet.length
                        if (!MiLinkPrivilegeHookPolicy.isDistAudioFeedFrameSize(length)) {
                            droppedBadSize += 1
                            if (badSizeLogged < 10) {
                                badSizeLogged += 1
                                log(
                                    "audiomonitor dist uplink feed bad size=$length " +
                                        "from=${packet.address?.hostAddress}:${packet.port} " +
                                        "head=${hexHead(packet.data, minOf(length, 8))}"
                                )
                            }
                            continue
                        }
                        val manager = instanceField.get(null)
                        val stream = manager?.let {
                            runCatching { streamField.get(it) }.getOrNull()
                        }
                        if (stream == null) {
                            droppedNoStream += 1
                            continue
                        }
                        val streamId = System.identityHashCode(stream)
                        if (streamId != lastStreamId) {
                            lastStreamId = streamId
                            log(
                                "audiomonitor dist uplink feed stream instance=$streamId " +
                                    "received=$received"
                            )
                        }
                        val frame = packet.data.copyOf(length)
                        runCatching {
                            playCastAudioData.invoke(stream, frame, received * 20_000L)
                        }.onSuccess {
                            fed += 1
                            if (fed == 1L || fed % 500L == 0L) {
                                log(
                                    "audiomonitor dist uplink feed progress fed=$fed " +
                                        "received=$received noStream=$droppedNoStream " +
                                        "badSize=$droppedBadSize"
                                )
                            }
                        }.onFailure { error ->
                            log(
                                "audiomonitor dist uplink feed invoke failed: " +
                                    "${error.javaClass.simpleName}: ${error.message}"
                            )
                        }
                    }
                }.onFailure { error ->
                    log(
                        "audiomonitor dist uplink feed died: " +
                            "${error.javaClass.simpleName}: ${error.message}"
                    )
                }
            }
        }.onFailure { error ->
            log(
                "failed to hook audiomonitor dist uplink feed: " +
                    "${error.javaClass.simpleName}: ${error.message}"
            )
        }
    }

    // The InCallUI's DistAudioDeviceProvider hard-filters remote audio
    // devices by deviceType 2/4/11. The Mac presents as an Apple-family
    // type (14 on the DH framework's cached HardwareInfo — the type flip
    // to 11 on the announce tdi + mDNS TXT does not propagate into the
    // cross-device device map, live 2026-09-05 21:02), so
    // RelayPresenter.connectRelayAudio() finds no route and the call audio
    // stays on the DAS-muted local mic — the far end hears nothing while
    // the full DistAudio uplink streams. Accept any paired remote type.
    // Also trace the RelayPresenter → route-lookup chain: live 2026-09-06
    // 10:58 the relayed call reached onRelayDeviceId with audioMode==2 but
    // no route connect followed; these hooks dump the provider maps at each
    // decision point so the next test call shows why.
    private fun hookInCallUiDistAudioTypeFilter(classLoader: ClassLoader) {
        runCatching {
            val providerClass = findTargetClass(
                classLoader, "com.android.incallui.relay.DistAudioDeviceProvider"
            )
            installHook(
                resolveMethod(providerClass, "isDeviceSupportType", Int::class.javaPrimitiveType!!)
            ) { chain ->
                val deviceType = chain.args.getOrNull(0) as? Int
                log("allowed dist audio device type=$deviceType")
                true
            }
            hookInCallUiDistAudioTracing(classLoader, providerClass)
        }.onFailure { error ->
            log("failed to hook incallui dist audio type filter: " +
                "${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookInCallUiDistAudioTracing(classLoader: ClassLoader, providerClass: Class<*>) {
        runCatching {
            val routesField = providerClass.getDeclaredField("mDistAudioRoutes").apply { isAccessible = true }
            val infosField = providerClass.getDeclaredField("mDistAudioDeviceInfos").apply { isAccessible = true }
            installHook(
                resolveMethod(providerClass, "findAudioRouteByDeviceId", String::class.java)
            ) { chain ->
                val deviceId = chain.args.getOrNull(0) as? String
                val result = chain.proceed()
                val provider = chain.thisObject
                val routes = runCatching { routesField.get(provider) as? Map<*, *> }.getOrNull()
                val infos = runCatching { infosField.get(provider) as? Map<*, *> }.getOrNull()
                log(
                    "incallui findAudioRoute deviceId=$deviceId hit=${result != null} " +
                        "routeKeys=${routes?.keys} infoKeys=${infos?.keys}"
                )
                result
            }
            installHook(resolveMethod(providerClass, "getAllDistAudioRoutes")) { chain ->
                val result = chain.proceed()
                val provider = chain.thisObject
                val infos = runCatching { infosField.get(provider) as? Map<*, *> }.getOrNull()
                val dump = infos?.entries?.joinToString(",") { (key, value) ->
                    "$key(type=${runCatching { callTargetMethod(value!!, "c") }.getOrNull()})"
                }
                log("incallui getAllDistAudioRoutes devices=$dump")
                result
            }
            installHook(resolveMethod(providerClass, "registerMiAudioManager")) { chain ->
                val result = chain.proceed()
                val manager = runCatching {
                    providerClass.getDeclaredField("mMiAudioManager")
                        .apply { isAccessible = true }.get(chain.thisObject)
                }.getOrNull()
                log("incallui registerMiAudioManager done managerNull=${manager == null}")
                result
            }
        }.onFailure { error ->
            log("failed to hook incallui dist audio tracing: " +
                "${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            val presenterClass = findTargetClass(
                classLoader, "com.android.incallui.relay.RelayPresenter"
            )
            val callField = presenterClass.getDeclaredField("mCall").apply { isAccessible = true }
            installHook(resolveMethod(presenterClass, "connectRelayAudio")) { chain ->
                val call = runCatching { callField.get(chain.thisObject) }.getOrNull()
                val extras = runCatching {
                    callTargetMethod(call!!, "getRelayExtra") as? Bundle
                }.getOrNull()
                log("incallui connectRelayAudio entered extras=$extras")
                chain.proceed()
            }
        }.onFailure { error ->
            log("failed to hook incallui relay presenter: " +
                "${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun installMirrorCastChannelTracker(classLoader: ClassLoader) {
        runCatching {
            val listenerClass = findTargetClass(classLoader, "o2.F\$c")
            installHook(
                resolveMethod(
                    listenerClass,
                    "onChannelConfirm",
                    String::class.java,
                    findTargetClass(classLoader, "com.xiaomi.continuity.ServiceName"),
                    Integer.TYPE,
                    findTargetClass(classLoader, "com.xiaomi.continuity.channel.ConfirmInfo")
                )
            ) { chain ->
                val deviceId = chain.args.getOrNull(0) as? String
                val serviceName = chain.args.getOrNull(1)?.toString().orEmpty()
                if (serviceName.contains("com.xiaomi.mirror") && serviceName.contains("cast")) {
                    lastCastChannelConfirmAtMs = System.currentTimeMillis()
                    lastCastChannelConfirmDevice = deviceId.orEmpty()
                    log("mirror cast channel confirmed device=$deviceId service=$serviceName")
                }
                chain.proceed()
            }
        }.onFailure { error ->
            log("mirror cast channel tracker hook failed: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun installHook(executable: Executable, hooker: XposedInterface.Hooker) {
        xposed.hook(executable)
            .setExceptionMode(XposedInterface.ExceptionMode.PROTECTIVE)
            .intercept(hooker)
    }

    private fun findTargetClass(classLoader: ClassLoader, className: String): Class<*> =
        Class.forName(className, false, classLoader)

    private fun resolveMethod(targetClass: Class<*>, methodName: String, vararg parameterTypes: Class<*>): Method {
        var current: Class<*>? = targetClass
        while (current != null) {
            val method = runCatching { current.getDeclaredMethod(methodName, *parameterTypes) }.getOrNull()
            if (method != null) {
                return method
            }
            current = current.superclass
        }
        throw NoSuchMethodException("${targetClass.name}#$methodName(${parameterTypes.size} params)")
    }

    private fun log(message: String) {
        xposed.log(Log.INFO, LOG_TAG, message)
    }

    private fun hookXiaomiMirrorSystemPackageGids(classLoader: ClassLoader) {
        hookXiaomiMirrorPackageGidsMethod(classLoader, "com.android.server.pm.ComputerEngine")
        hookXiaomiMirrorPackageGidsMethod(classLoader, "com.android.server.pm.IPackageManagerBase")
    }

    private fun hookXiaomiMirrorPackageGidsMethod(classLoader: ClassLoader, className: String) {
        runCatching {
            installHook(
                resolveMethod(
                    findTargetClass(classLoader, className),
                    "getPackageGids",
                    String::class.java,
                    java.lang.Long.TYPE,
                    Integer.TYPE
                )
            ) { chain ->
                val result = chain.proceed()
                val packageName = chain.args.getOrNull(0) as? String
                if (packageName != MiLinkPrivilegeHookPolicy.XIAOMI_MIRROR_PACKAGE) {
                    return@installHook result
                }
                val original = result as? IntArray ?: IntArray(0)
                val updated = appendIntIfMissing(original, XIAOMI_MIRROR_UHID_GID)
                if (updated !== original) {
                    log(
                        "mirror package gids appended class=$className " +
                            "package=$packageName gid=$XIAOMI_MIRROR_UHID_GID " +
                            "before=${original.joinToString(",")} after=${updated.joinToString(",")}"
                    )
                }
                updated
            }
            log("hooked mirror package gids class=$className")
        }.onFailure { error ->
            log("failed to hook mirror package gids class=$className: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookRuntimeCallingPackageCheck(classLoader: ClassLoader) {
        runCatching {
            installHook(
                resolveMethod(
                    findTargetClass(classLoader, MILINK_PRIVILEGED_PACKAGE_MANAGER),
                    "e",
                    Context::class.java,
                    String::class.java
                )
            ) { chain ->
                val callerPackage = chain.args.getOrNull(1) as? String
                if (MiLinkPrivilegeHookPolicy.isAllowedCallerPackage(callerPackage)) {
                    log("allowed provider callerPackage=$callerPackage")
                    return@installHook true
                }
                chain.proceed()
            }
        }.onFailure { error ->
            log("failed to hook provider package check: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookRuntimeCallingUidCheck(classLoader: ClassLoader) {
        runCatching {
            installHook(
                resolveMethod(
                    findTargetClass(classLoader, MILINK_PRIVILEGED_PACKAGE_MANAGER),
                    "d",
                    Context::class.java
                )
            ) { chain ->
                val context = chain.args.getOrNull(0) as? Context
                if (context != null) {
                    val packages = context.packageManager.getPackagesForUid(Binder.getCallingUid())
                    if (MiLinkPrivilegeHookPolicy.hasAllowedCallerPackage(packages)) {
                        log("allowed binder callerUid=${Binder.getCallingUid()}")
                        return@installHook true
                    }
                }
                chain.proceed()
            }
        }.onFailure { error ->
            log("failed to hook binder uid check: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookCastClientServiceCheck(classLoader: ClassLoader) {
        runCatching {
            installHook(
                resolveMethod(findTargetClass(classLoader, MILINK_BASE_CLIENT_SERVICE), "b")
            ) { chain ->
                val context = chain.thisObject as? Context
                if (context != null) {
                    val packages = context.packageManager.getPackagesForUid(Binder.getCallingUid())
                    if (MiLinkPrivilegeHookPolicy.hasAllowedCallerPackage(packages)) {
                        log("allowed cast service callerUid=${Binder.getCallingUid()}")
                        return@installHook null
                    }
                }
                chain.proceed()
            }
        }.onFailure { error ->
            log("failed to hook cast client service check: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorWifiOpenGate(classLoader: ClassLoader) {
        runCatching {
            if (readSystemProperty("debug.edgelink.mirror_wifi_gate") == "off") {
                log("mirror wifi-open gate hook disabled by property")
                return@runCatching
            }
            val controllerClass = findTargetClass(classLoader, XIAOMI_MIRROR_WIFI_OPEN_CONTROLLER)
            val callbackClass = findTargetClass(classLoader, XIAOMI_MIRROR_WIFI_OPEN_CALLBACK)
            val taskClass = findTargetClass(classLoader, XIAOMI_MIRROR_WIFI_OPEN_TASK)
            installHook(
                resolveMethod(controllerClass, "k", callbackClass)
            ) { chain ->
                val callback = chain.args.getOrNull(0)
                if (callback == null) {
                    return@installHook chain.proceed()
                }
                log("mirror wifi-open dialog bypassed, continuing connect")
                val deliver = {
                    runCatching {
                        callbackClass.getMethod("onSuccess").invoke(callback)
                    }.onFailure { error ->
                        log("mirror wifi-open onSuccess failed: ${error.javaClass.simpleName}: ${error.message}")
                    }
                }
                if (Looper.myLooper() == Looper.getMainLooper()) {
                    deliver()
                } else {
                    Handler(Looper.getMainLooper()).post { deliver() }
                }
                null
            }
            installHook(
                resolveMethod(controllerClass, "l", Integer.TYPE, taskClass)
            ) { chain ->
                val task = chain.args.getOrNull(1)
                if (task == null) {
                    return@installHook chain.proceed()
                }
                log("mirror wifi-open blocking gate bypassed")
                taskClass.getMethod("run").invoke(task) as? Int ?: chain.proceed()
            }
            installHook(
                resolveMethod(controllerClass, "j")
            ) { _ ->
                true
            }
            log("mirror wifi-open gate hooked")
        }.onFailure { error ->
            log("failed to hook mirror wifi-open gate: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorDeviceManagerAdmit(classLoader: ClassLoader) {
        runCatching {
            val managerClass = findTargetClass(classLoader, MIRROR_DEVICE_MANAGER_CLASS)
            val entityClass = findTargetClass(classLoader, MIRROR_DEVICE_ENTITY_CLASS)
            val storeClass = findTargetClass(classLoader, MIRROR_DEVICE_STORE_CLASS)
            val businessBaseClass = findTargetClass(classLoader, MIRROR_BUSINESS_BASE_CLASS)
            val businessHandlerClass = findTargetClass(classLoader, MIRROR_BUSINESS_HANDLER_CLASS)
            val deviceInfoClass = findTargetClass(classLoader, MIRROR_TRUSTED_DEVICE_INFO_CLASS)
            val serviceInfoClass = findTargetClass(classLoader, MIRROR_BUSINESS_SERVICE_INFO_CLASS)
            installHook(
                resolveMethod(managerClass, "q", String::class.java)
            ) { chain ->
                val result = chain.proceed()
                val deviceId = chain.args.getOrNull(0) as? String
                if (result != null || deviceId == null || deviceId !in MIRROR_ADMIT_DEVICE_IDS) {
                    return@installHook result
                }
                val admitId: String = deviceId
                val manager = chain.thisObject ?: return@installHook result
                runCatching {
                    val deviceInfo = deviceInfoClass.getConstructor().newInstance()
                    deviceInfoClass.getMethod("k", String::class.java).invoke(deviceInfo, admitId)
                    deviceInfoClass.getMethod("l", String::class.java).invoke(deviceInfo, "EdgeLink Mac")
                    deviceInfoClass.getMethod("m", Integer.TYPE).invoke(deviceInfo, 14)
                    deviceInfoClass.getDeclaredField("d").apply { isAccessible = true }.setInt(deviceInfo, 128)
                    deviceInfoClass.getDeclaredField("e").apply { isAccessible = true }.setInt(deviceInfo, 1)

                    val businessBase = managerClass.getDeclaredField("b")
                        .apply { isAccessible = true }.get(manager)
                    val makeHandler = businessBaseClass.getMethod("b", Integer.TYPE, ByteArray::class.java)
                    val handler = makeHandler.invoke(businessBase, 1, byteArrayOf(0x0C, 0x00))
                        ?: error("business handler factory returned null")

                    val context = managerClass.getDeclaredField("a")
                        .apply { isAccessible = true }.get(manager)
                    val store = managerClass.getDeclaredField("g")
                        .apply { isAccessible = true }.get(manager)
                    val entity = entityClass.getConstructor(
                        android.content.Context::class.java,
                        String::class.java,
                        deviceInfoClass,
                        serviceInfoClass,
                        businessBaseClass,
                        businessHandlerClass,
                        storeClass
                    ).newInstance(context, admitId, deviceInfo, null, businessBase, handler, store)

                    @Suppress("UNCHECKED_CAST")
                    val deviceMap = managerClass.getDeclaredField("c")
                        .apply { isAccessible = true }.get(manager) as? MutableMap<String, Any>
                        ?: error("device map missing")
                    deviceMap[admitId] = entity
                    log("mirror device manager admitted device=$admitId")
                }.onFailure { error ->
                    log("mirror device manager admit failed device=$admitId: ${error.message}")
                }
                chain.proceed()
            }
        }.onFailure { error ->
            log("failed to hook mirror device manager: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorUnlockIslandGate(classLoader: ClassLoader) {
        runCatching {
            val trustManagerClass = findTargetClass(classLoader, MIRROR_TRUST_MANAGER_CLASS)
            val trustMessageClass = findTargetClass(classLoader, "com.xiaomi.mirror.message.TrustMessage")
            installHook(
                resolveMethod(trustManagerClass, "J", String::class.java, trustMessageClass)
            ) { chain ->
                val result = chain.proceed()
                val deviceId = chain.args.getOrNull(0) as? String
                val message = chain.args.getOrNull(1)
                if (deviceId != null && deviceId in MIRROR_ADMIT_DEVICE_IDS &&
                    message != null &&
                    message.javaClass.name.contains("AuthEventMessage")
                ) {
                    val code = runCatching {
                        message.javaClass.getDeclaredField("code").apply { isAccessible = true }.getInt(message)
                    }.getOrDefault(-1)
                    if (code == 0) {
                        log("mirror unlock island post device=$deviceId")
                        postMirrorUnlockIsland(classLoader, deviceId, delayMs = 0)
                        postMirrorUnlockIsland(classLoader, deviceId, delayMs = 3000)
                    }
                }
                result
            }
        }.onFailure { error ->
            log("failed to hook mirror unlock island gate: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun postMirrorUnlockIsland(classLoader: ClassLoader, deviceId: String, delayMs: Long) {
        val post = {
            runCatching {
                val mirrorClass = findTargetClass(classLoader, "com.xiaomi.mirror.Mirror")
                val context = mirrorClass.getMethod("z").invoke(null) as? android.content.Context
                    ?: error("Mirror.z() returned null")
                val islandClass = findTargetClass(classLoader, "com.xiaomi.mirror.cast.a")
                islandClass.getMethod("o", android.content.Context::class.java, String::class.java)
                    .invoke(null, context, deviceId)
                log("mirror unlock island posted device=$deviceId delayMs=$delayMs")
            }.onFailure { error ->
                log("mirror unlock island post failed device=$deviceId delayMs=$delayMs: ${error.message}")
            }
        }
        if (delayMs <= 0) {
            post()
        } else {
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ post() }, delayMs)
        }
    }

    private fun hookMirrorCallProviderAccessCheck(classLoader: ClassLoader) {
        runCatching {
            installHook(
                resolveMethod(
                    findTargetClass(classLoader, XIAOMI_MIRROR_CALL_PROVIDER),
                    "g",
                    Integer.TYPE,
                    String::class.java
                )
            ) { chain ->
                val callerUid = chain.args.getOrNull(0) as? Int
                val method = chain.args.getOrNull(1) as? String
                if (callerUid != null &&
                    MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod(method)
                ) {
                    val context = (chain.thisObject as? ContentProvider)?.context
                    if (context != null) {
                        val packages = context.packageManager.getPackagesForUid(callerUid)
                        if (MiLinkPrivilegeHookPolicy.hasAllowedCallerPackage(packages)) {
                            log("allowed mirror call provider method=$method callerUid=$callerUid")
                            return@installHook null
                        }
                    }
                }
                chain.proceed()
            }
        }.onFailure { error ->
            log("failed to hook mirror call provider check: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorOfficialScreenConfiguration(classLoader: ClassLoader) {
        runCatching {
            val managerClass = findTargetClass(classLoader, XIAOMI_MIRROR_MESSAGE_MANAGER)
            val methods = managerClass.declaredMethods.filter { method ->
                method.name == "notifyDisplayChanged" || method.name == "notifyDisplayCreated"
            }
            check(methods.isNotEmpty()) { "official display notification methods not found" }
            methods.forEach { method ->
                installHook(method) { chain ->
                    val result = chain.proceed()
                    val isCreated = method.name == "notifyDisplayCreated"
                    val display = chain.args.getOrNull(if (isCreated) 1 else 0)
                    if (display != null) {
                        val screenId = runCatching {
                            (callTargetMethod(display, "getScreenId") as Number).toInt()
                        }.getOrNull()
                        if (screenId == XIAOMI_MIRROR_MAIN_SCREEN_ID) {
                            val remoteId = runCatching {
                                callTargetMethod(display, "A") as? String
                            }.getOrNull()
                            log(
                                "mirror official screen config observed kind=${if (isCreated) "onCreate" else "sizeChanged"} " +
                                    "screen=$screenId remoteId=${remoteId.orEmpty()}"
                            )
                            bridgeOfficialScreenConfiguration(
                                classLoader = classLoader,
                                display = display,
                                terminal = if (isCreated) chain.args.getOrNull(0) else null,
                                isCreated = isCreated
                            )
                        }
                    }
                    result
                }
            }
            log("mirror official screen configuration hooks installed count=${methods.size}")
        }.onFailure { error ->
            log("failed to hook official mirror screen configuration: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun bridgeOfficialScreenConfiguration(
        classLoader: ClassLoader,
        display: Any,
        terminal: Any?,
        isCreated: Boolean
    ) {
        runCatching {
            val screenId = (callTargetMethod(display, "getScreenId") as Number).toInt()
            val displayConfig = callTargetMethod(display, "c")
                ?: error("display config unavailable")
            val messageClass = findTargetClass(classLoader, XIAOMI_MIRROR_SCREEN_CONFIGURATION_MESSAGE)
            val message = if (isCreated) {
                val deviceId = runCatching {
                    terminal?.let { callTargetMethod(it, "h") as? String }
                }.getOrNull() ?: MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID
                val port = (callTargetMethod(display, "getPort") as Number).toInt()
                messageClass.methods.first { method ->
                    method.name == "generateOnCreateMsg" && method.parameterTypes.size == 4
                }.invoke(null, deviceId, screenId, port, displayConfig)
            } else {
                messageClass.methods.first { method ->
                    method.name == "generateSizeChangedMsg" && method.parameterTypes.size == 2
                }.invoke(null, screenId, displayConfig)
            }
            val converterClass = findTargetClass(classLoader, XIAOMI_MIRROR_MESSAGE_CONVERT)
            val converter = converterClass.getDeclaredConstructor().newInstance()
            val frame = converterClass.methods.first { method ->
                method.name == "encodeMsg" &&
                    method.parameterTypes.size == 2 &&
                    method.parameterTypes[1] == java.lang.Boolean.TYPE
            }.invoke(converter, message, false) as? ByteArray
                ?: error("official encoder returned no frame")
            check(frame.size >= 5 && frame[0].toInt() == XIAOMI_MIRROR_SCREEN_CONFIGURATION_TYPE) {
                "unexpected official frame type=${frame.firstOrNull()?.toInt()} bytes=${frame.size}"
            }
            broadcastOfficialScreenConfiguration(frame)
            val width = runCatching { (callTargetMethod(displayConfig, "y") as Number).toInt() }.getOrNull()
            val height = runCatching { (callTargetMethod(displayConfig, "s") as Number).toInt() }.getOrNull()
            log(
                "mirror official screen config bridged kind=${if (isCreated) "onCreate" else "sizeChanged"} " +
                    "screen=$screenId size=${width ?: 0}x${height ?: 0} bytes=${frame.size}"
            )
        }.onFailure { error ->
            log("failed to bridge official mirror screen configuration: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun broadcastOfficialScreenConfiguration(frame: ByteArray) {
        val context = currentApplicationContext()
            ?: error("application context unavailable")
        val intent = Intent(MiLinkPrivilegeHookPolicy.XIAOMI_MIRROR_CAST_FRAME_ACTION)
            .setPackage(MiLinkPrivilegeHookPolicy.EDGE_LINK_PACKAGE)
            .setClassName(
                MiLinkPrivilegeHookPolicy.EDGE_LINK_PACKAGE,
                "${MiLinkPrivilegeHookPolicy.EDGE_LINK_PACKAGE}.EdgeLinkXiaomiMirrorCastReceiver"
            )
            .putExtra(MiLinkPrivilegeHookPolicy.XIAOMI_MIRROR_CAST_FRAME_EXTRA, frame)
            .putExtra("ts", System.currentTimeMillis())
        context.sendBroadcast(intent)
    }

    private fun hookMirrorSourceRecoveryProvider(classLoader: ClassLoader) {
        runCatching {
            installHook(
                resolveMethod(
                    findTargetClass(classLoader, XIAOMI_MIRROR_CALL_PROVIDER),
                    "f",
                    Integer.TYPE,
                    String::class.java,
                    String::class.java,
                    String::class.java,
                    Bundle::class.java
                )
            ) { chain ->
                val method = chain.args.getOrNull(2) as? String
                val extras = chain.args.getOrNull(4) as? Bundle
                if (extras != null && method == "edgeLinkCastChannel") {
                    return@installHook Bundle().apply {
                        putLong("castChannelConfirmAtMs", lastCastChannelConfirmAtMs)
                        putString("castChannelDevice", lastCastChannelConfirmDevice)
                        putBoolean("enable", true)
                        putInt("value", 0)
                    }
                }
                chain.proceed()
            }
            log("mirror edgelink provider hook installed")
        }.onFailure { error ->
            log("failed to hook mirror edgelink provider: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun appendIntIfMissing(values: IntArray, value: Int): IntArray =
        if (values.contains(value)) {
            values
        } else {
            values + value
        }

    private fun xiaomiMirrorApplicationContext(classLoader: ClassLoader): Context? =
        currentApplicationContext()
            ?: runCatching {
                findTargetClass(classLoader, XIAOMI_MIRROR_APPLICATION)
                    .getMethod("z")
                    .invoke(null) as? Context
            }.getOrNull()?.applicationContext

    private fun callTargetMethod(target: Any, methodName: String): Any? =
        target.javaClass.getMethod(methodName).invoke(target)

    private fun currentApplicationContext(): Context? =
        runCatching {
            Class.forName("android.app.ActivityThread")
                .getMethod("currentApplication")
                .invoke(null) as? Context
        }.getOrNull()?.applicationContext

    private fun readSystemProperty(name: String): String =
        runCatching {
            Class.forName("android.os.SystemProperties")
                .getMethod("get", String::class.java, String::class.java)
                .invoke(null, name, "") as? String
        }.getOrNull().orEmpty()

    private fun hookMiShareLyraTrustInjection(classLoader: ClassLoader) {
        runCatching {
            val runtimeNative = findTargetClass(
                classLoader,
                "com.xiaomi.continuity.nativelib.ContinuityRuntimeNative"
            )
            runtimeNative.getDeclaredMethod("nativeSetLogLevel", Integer.TYPE).invoke(null, 1)
            log("mishare trust injection: native log level set to 1")
        }.onFailure {
            val cause = it.cause ?: it
            log("mishare trust injection: set native log level failed: ${cause.message}")
        }

        val managerClass = runCatching {
            findTargetClass(classLoader, "com.xiaomi.continuity.networking.NetworkingManager")
        }.getOrNull()
        if (managerClass == null) {
            log("mishare trust injection: NetworkingManager not found, skip")
            return
        }

        var hookedCount = 0
        for (method in managerClass.declaredMethods) {
            if (method.name != "addServiceListener" || method.parameterTypes.size != 2) {
                continue
            }
            installHook(method) { chain ->
                val result = chain.proceed()
                val serviceListener = chain.args.getOrNull(1)
                if (serviceListener != null) {
                    registerMiShareServiceListener(classLoader, chain.args.getOrNull(0), serviceListener)
                }
                result
            }
            hookedCount += 1
        }
        log("mishare trust injection: addServiceListener hookedCount=$hookedCount")
    }

    private fun registerMiShareServiceListener(
        classLoader: ClassLoader,
        serviceFilter: Any?,
        serviceListener: Any
    ): Boolean {
        val filterName = runCatching {
            val serviceName = serviceFilter?.let { callTargetMethod(it, "getServiceFilter") }
            serviceName?.let { callTargetMethod(it, "getName") as? String }
        }.getOrNull()
        log("mishare trust injection: addServiceListener filter=$filterName listener=$serviceListener")
        if (filterName == null || filterName !in MiShareTrustInjection.KNOWN_SERVICE_NAMES) {
            return false
        }
        log("mishare trust injection: captured listener=$serviceListener service=$filterName")
        MiShareTrustInjection.registerListener(classLoader, filterName, serviceListener) { message ->
            log("mishare trust injection: $message")
        }
        return true
    }

    companion object {
        const val LOG_TAG = "EdgeLinkMiLinkHook"

        private var lastCastChannelConfirmAtMs = 0L
        private var lastCastChannelConfirmDevice = ""
        private const val MIRROR_DEVICE_MANAGER_CLASS = "o2.C"
        private const val MIRROR_DEVICE_ENTITY_CLASS = "o2.e"
        private const val MIRROR_DEVICE_STORE_CLASS = "o2.L"
        private const val MIRROR_BUSINESS_BASE_CLASS = "n2.c"
        private const val MIRROR_BUSINESS_HANDLER_CLASS = "n2.c\$a"
        private const val MIRROR_TRUSTED_DEVICE_INFO_CLASS = "com.xiaomi.continuity.networking.TrustedDeviceInfo"
        private const val MIRROR_BUSINESS_SERVICE_INFO_CLASS =
            "com.xiaomi.continuity.networking.BusinessServiceInfo"
        private val MIRROR_ADMIT_DEVICE_IDS = setOf("721572C3")
        private const val MIRROR_TRUST_MANAGER_CLASS = "com.xiaomi.mirror.trust.k"
        private const val MILINK_BASE_CLIENT_SERVICE = "com.milink.client.BaseClientService"
        private const val MILINK_PRIVILEGED_PACKAGE_MANAGER = "com.milink.base.utils.p"
        private const val XIAOMI_MIRROR_CALL_PROVIDER = "com.xiaomi.mirror.provider.CallProvider"
        private const val XIAOMI_MIRROR_APPLICATION = "com.xiaomi.mirror.Mirror"
        private const val XIAOMI_MIRROR_MESSAGE_MANAGER = "com.xiaomi.mirror.message.MessageManagerImpl"
        private const val XIAOMI_MIRROR_SCREEN_CONFIGURATION_MESSAGE =
            "com.xiaomi.mirror.message.ScreenConfigurationChangedMessage"
        private const val XIAOMI_MIRROR_MESSAGE_CONVERT = "com.xiaomi.mirror.message.MessageConvert"
        private const val XIAOMI_MIRROR_SCREEN_CONFIGURATION_TYPE = 5
        private const val XIAOMI_MIRROR_MAIN_SCREEN_ID = 0
        private const val XIAOMI_MIRROR_UHID_GID = 3011
        private const val XIAOMI_MIRROR_WIFI_OPEN_CONTROLLER = "p2.x"
        private const val XIAOMI_MIRROR_WIFI_OPEN_CALLBACK = "p2.x\$c"
        private const val XIAOMI_MIRROR_WIFI_OPEN_TASK = "p2.x\$e"
    }
}
