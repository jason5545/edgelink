package com.edgelink.app

import android.content.Context
import android.content.ContentProvider
import android.content.Intent
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCrypto
import android.media.MediaFormat
import android.os.Binder
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.Parcelable
import android.os.SystemClock
import android.view.Surface
import android.view.SurfaceHolder
import android.view.View
import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage
import java.lang.reflect.Modifier
import java.net.InetAddress
import java.util.ArrayList
import java.util.Collections
import java.util.HashMap
import java.util.WeakHashMap
import java.util.concurrent.ConcurrentHashMap

internal object MiLinkPrivilegeHookPolicy {
    const val EDGE_LINK_PACKAGE = "com.edgelink.app"
    const val MILINK_PACKAGE = "com.milink.service"
    const val MILINK_MAIN_PROCESS = "com.milink.service"
    const val MILINK_RUNTIME_PROCESS = "com.milink.runtime"
    const val MILINK_DISTRIBUTED_HARDWARE_PROCESS = "com.milink.service:distributedHardware"
    const val XIAOMI_MIRROR_PACKAGE = "com.xiaomi.mirror"
    const val XIAOMI_MIRROR_PROCESS = "com.xiaomi.mirror"
    const val XIAOMI_MI_CONNECT_PACKAGE = "com.xiaomi.mi_connect_service"
    const val XIAOMI_MI_CONNECT_PROCESS = "com.xiaomi.mi_connect_service"
    const val INCALLUI_PACKAGE = "com.android.incallui"
    const val INCALLUI_PROCESS = "com.android.incallui"
    const val ANDROID_PHONE_PACKAGE = "com.android.phone"
    const val ANDROID_PHONE_PROCESS = "com.android.phone"
    const val SYSTEM_SERVER_PROCESS = "system_server"
    const val SYSTEM_PROCESS = "system"
    const val TELECOM_PACKAGE = "com.android.server.telecom"
    const val PHONE_RELAY_SELECTED_ACTION = "com.edgelink.app.PHONE_RELAY_SELECTED"
    const val PHONE_RELAY_SELECTED_REASON_EXTRA = "reason"
    const val MIRROR_FAKE_REMOTE_PROPERTY = "debug.edgelink.mirror_fake_remote"
    const val MIRROR_FAKE_REMOTE_ATTACH_PROPERTY = "debug.edgelink.mirror_fake_remote_attach"
    const val MIRROR_FAKE_REMOTE_KEY_PROPERTY = "debug.edgelink.mirror_fake_remote_key"
    const val MIRROR_FAKE_REMOTE_USING_PAD_PROPERTY = "debug.edgelink.mirror_fake_remote_using_pad"
    const val MIRROR_FAKE_REMOTE_CALL_RELAY_UNTIL_PROPERTY = "debug.edgelink.mirror_fake_remote_call_relay_until"
    const val MIRROR_FAKE_REMOTE_SCREEN_PROPERTY = "debug.edgelink.mirror_fake_remote_screen"
    const val MIRROR_FAKE_REMOTE_SCREEN_UNTIL_PROPERTY = "debug.edgelink.mirror_fake_remote_screen_until"
    const val MIRROR_FAKE_REMOTE_CALL_STATE_PROPERTY = "debug.edgelink.mirror_fake_remote_call_state"
    const val MIRROR_FAKE_REMOTE_AUDIO_PROPERTY = "debug.edgelink.mirror_fake_remote_audio"
    const val MIRROR_FAKE_REMOTE_AUDIO_PARAMS_PROPERTY = "debug.edgelink.mirror_fake_remote_audio_params"
    const val MIRROR_FAKE_REMOTE_AUDIO_START_PROPERTY = "debug.edgelink.mirror_fake_remote_audio_start"
    const val MIRROR_FAKE_REMOTE_AUDIO_SINK_ARG_PROPERTY = "debug.edgelink.mirror_fake_remote_audio_sink_arg"
    const val MIRROR_FAKE_REMOTE_PLAIN_RTP_PROPERTY = "debug.edgelink.mirror_fake_remote_plain_rtp"
    const val MIRROR_FAKE_REMOTE_PEER_IP_PROPERTY = "debug.edgelink.mirror_fake_remote_peer_ip"
    const val MIRROR_FAKE_REMOTE_PEER_PORT_PROPERTY = "debug.edgelink.mirror_fake_remote_peer_port"
    const val MIRROR_FAKE_REMOTE_LOCAL_IP_PROPERTY = "debug.edgelink.mirror_fake_remote_local_ip"
    const val MIRROR_FAKE_REMOTE_LOCAL_PORT_PROPERTY = "debug.edgelink.mirror_fake_remote_local_port"
    const val FAKE_MIRROR_REMOTE_ID = "edgelink-mac-mi-pad"
    const val FAKE_MIRROR_REMOTE_NAME = "EdgeLink Mac"

    private val mirrorPhoneProviderMethods = setOf(
        "getAliveBinder",
        "queryRemoteDevices",
        "queryRemoteDevice",
        "startShare",
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
        "setMediaRelayVolume"
    )

    fun shouldHook(packageName: String?, processName: String?): Boolean =
        shouldHookRuntime(packageName, processName) ||
            shouldHookMainService(packageName, processName) ||
            shouldHookDistributedHardware(packageName, processName) ||
            shouldHookXiaomiMirror(packageName, processName) ||
            shouldHookMiConnectService(packageName, processName) ||
            shouldHookInCallUi(packageName, processName) ||
            shouldHookAndroidPhone(packageName, processName) ||
            shouldHookTelecomSystem(packageName, processName)

    fun shouldHookRuntime(packageName: String?, processName: String?): Boolean =
        packageName == MILINK_PACKAGE && processName == MILINK_RUNTIME_PROCESS

    fun shouldHookMainService(packageName: String?, processName: String?): Boolean =
        packageName == MILINK_PACKAGE && processName == MILINK_MAIN_PROCESS

    fun shouldHookDistributedHardware(packageName: String?, processName: String?): Boolean =
        packageName == MILINK_PACKAGE && processName == MILINK_DISTRIBUTED_HARDWARE_PROCESS

    fun shouldHookXiaomiMirror(packageName: String?, processName: String?): Boolean =
        packageName == XIAOMI_MIRROR_PACKAGE && processName == XIAOMI_MIRROR_PROCESS

    fun shouldHookMiConnectService(packageName: String?, processName: String?): Boolean =
        packageName == XIAOMI_MI_CONNECT_PACKAGE && processName == XIAOMI_MI_CONNECT_PROCESS

    fun shouldHookInCallUi(packageName: String?, processName: String?): Boolean =
        packageName == INCALLUI_PACKAGE && processName == INCALLUI_PROCESS

    fun shouldHookAndroidPhone(packageName: String?, processName: String?): Boolean =
        packageName == ANDROID_PHONE_PACKAGE && processName == ANDROID_PHONE_PROCESS

    fun shouldHookTelecomSystem(packageName: String?, processName: String?): Boolean {
        val telecomPackage = packageName == TELECOM_PACKAGE
        val telecomProcess = processName == null ||
            processName == TELECOM_PACKAGE ||
            processName == SYSTEM_SERVER_PROCESS ||
            processName == SYSTEM_PROCESS
        return telecomPackage && telecomProcess
    }

    fun isAllowedCallerPackage(packageName: String?): Boolean =
        packageName == EDGE_LINK_PACKAGE

    fun hasAllowedCallerPackage(packages: Array<String>?): Boolean =
        packages?.any(::isAllowedCallerPackage) == true

    fun isAllowedMiConnectCallerPackage(requestedPackageName: String?, callerPackages: Array<String>?): Boolean {
        if (requestedPackageName != null && !isAllowedCallerPackage(requestedPackageName)) {
            return false
        }
        return hasAllowedCallerPackage(callerPackages)
    }

    fun isAllowedMirrorPhoneProviderMethod(method: String?): Boolean =
        method in mirrorPhoneProviderMethods

    fun mirrorFakeRemoteMode(rawValue: String?): String? =
        when (rawValue?.trim()?.lowercase()) {
            "pad", "mipad", "androidpad" -> "pad"
            "car", "androidpadcar" -> "car"
            else -> null
        }

    fun mirrorFakeRemoteAttachEnabled(rawValue: String?): Boolean =
        when (rawValue?.trim()?.lowercase()) {
            "1", "true", "yes", "on", "attach" -> true
            else -> false
        }

    fun mirrorFakeRemoteKeyEnabled(rawValue: String?): Boolean =
        when (rawValue?.trim()?.lowercase()) {
            "1", "true", "yes", "on", "key", "probe" -> true
            else -> false
        }

    fun mirrorFakeRemoteUsingPadEnabled(rawValue: String?): Boolean =
        when (rawValue?.trim()?.lowercase()) {
            "1", "true", "yes", "on", "pad", "usingpad", "using_pad" -> true
            else -> false
        }

    fun mirrorFakeRemoteCallRelayUntil(rawValue: String?): Long? {
        val normalized = rawValue?.trim()?.takeIf { it.length in 1..16 } ?: return null
        if (normalized.any { it !in '0'..'9' }) {
            return null
        }
        return normalized.toLongOrNull()
    }

    fun mirrorFakeRemoteCallRelayActive(rawValue: String?, nowEpochMs: Long): Boolean =
        mirrorFakeRemoteCallRelayUntil(rawValue)?.let { untilEpochMs ->
            untilEpochMs > nowEpochMs
        } == true

    fun mirrorFakeRemoteScreenUntil(rawValue: String?): Long? {
        val normalized = rawValue?.trim()?.takeIf { it.length in 1..16 } ?: return null
        if (normalized.any { it !in '0'..'9' }) {
            return null
        }
        return normalized.toLongOrNull()
    }

    fun mirrorFakeRemoteScreenActive(rawValue: String?, nowEpochMs: Long): Boolean =
        mirrorFakeRemoteScreenUntil(rawValue)?.let { untilEpochMs ->
            untilEpochMs > nowEpochMs
        } == true

    fun mirrorFakeRemoteCallState(rawValue: String?): Int? =
        when (rawValue?.trim()?.lowercase()) {
            "0", "idle" -> 0
            "1", "ringing" -> 1
            "2", "offhook", "off_hook", "active" -> 2
            else -> null
        }

    fun mirrorFakeRemoteAudioAllowed(rawValue: String?): Boolean =
        when (rawValue?.trim()?.lowercase()) {
            "1", "true", "yes", "on", "allow", "audio" -> true
            else -> false
        }

    fun mirrorFakeRemoteAudioParamsEnabled(rawValue: String?): Boolean =
        when (rawValue?.trim()?.lowercase()) {
            "1", "true", "yes", "on", "params", "probe" -> true
            else -> false
        }

    fun mirrorFakeRemoteAudioStartMode(rawValue: String?): String? =
        when (rawValue?.trim()?.lowercase()) {
            "1", "true", "yes", "on", "probe", "source", "audio_source", "start_source" -> "source"
            "sink", "audio_sink", "start_sink" -> "sink"
            "both", "all", "source_sink", "source+sink" -> "both"
            else -> null
        }

    fun mirrorFakeRemoteAudioSinkArg(rawValue: String?): Int? =
        rawValue?.trim()?.toIntOrNull()?.takeIf { it in 1..65535 }

    fun mirrorFakeRemotePlainRtpEnabled(rawValue: String?): Boolean =
        when (rawValue?.trim()?.lowercase()) {
            "0", "false", "no", "off", "encrypt", "encrypted" -> false
            else -> true
        }

    fun mirrorFakeRemoteEndpointHost(rawValue: String?): String? =
        rawValue
            ?.trim()
            ?.takeIf { value ->
                value.isNotEmpty() &&
                    value.length <= MAX_ENDPOINT_HOST_CHARS &&
                    value.none { it.isWhitespace() }
            }

    fun mirrorFakeRemoteEndpointPort(rawValue: String?): Int? =
        rawValue?.trim()?.toIntOrNull()?.takeIf { it in 1..65535 }

    fun fakeMirrorRemotePlatform(mode: String): String =
        if (mode == "car") "AndroidPadCar" else "AndroidPad"

    fun shouldIncludeFakeMirrorRemote(
        mode: String,
        manufacturer: String?,
        platform: String?
    ): Boolean {
        val manufacturerOk = manufacturer.isNullOrBlank() ||
            manufacturer.equals("xiaomi", ignoreCase = true)
        val platformOk = platform.isNullOrBlank() ||
            platform.equals(fakeMirrorRemotePlatform(mode), ignoreCase = true)
        return manufacturerOk && platformOk
    }

    fun isFakeMirrorRemoteId(deviceId: String?): Boolean =
        deviceId == FAKE_MIRROR_REMOTE_ID

    private const val MAX_ENDPOINT_HOST_CHARS = 80
}

class MiLinkPrivilegeXposedHook : IXposedHookLoadPackage {
    private data class FakeMirrorSinkSurface(
        val texture: SurfaceTexture,
        val surface: Surface
    ) {
        fun release() {
            runCatching { surface.release() }
            runCatching { texture.release() }
        }
    }

    private data class MirrorHEVCEncoderState(
        val codec: MediaCodec,
        val codecId: Int,
        val configuredUptimeMs: Long,
        val mime: String,
        val formatSummary: String,
        var started: Boolean = false,
        var released: Boolean = false,
        var lastSyncRequestUptimeMs: Long = 0L
    )

    private val fakeMirrorSinkSurfaces = ConcurrentHashMap<Int, FakeMirrorSinkSurface>()
    private var lastFakeMirrorAttachUptimeMs: Long = 0L
    private var lastFakeMirrorKeyUptimeMs: Long = 0L
    private var lastFakeMirrorAudioParamsUptimeMs: Long = 0L
    private var lastFakeMirrorAudioStartProbeUptimeMs: Long = 0L
    private var lastFakeMirrorAudioSourceStartUptimeMs: Long = 0L
    private var lastFakeMirrorAudioSinkStartUptimeMs: Long = 0L
    private var lastFakeMirrorTerminalReadyUptimeMs: Long = 0L
    private var fakeMirrorSourceRouteUntilUptimeMs: Long = 0L
    private var fakeMirrorSourceSessionUntilUptimeMs: Long = 0L
    private var fakeMirrorSourceOptionHandle: Long = 0L
    private var lastFakeMirrorControlSource: Any? = null
    private var lastFakeMirrorControlSourceUptimeMs: Long = 0L
    private val liveMirrorHEVCEncoders =
        Collections.synchronizedMap(WeakHashMap<MediaCodec, MirrorHEVCEncoderState>())
    private var fakeMirrorSourceAuthConfigDepth: Int = 0
    private var mirrorSourceClassDiagnosticsLogged: Boolean = false
    private var mirrorControlClassDiagnosticsLogged: Boolean = false
    private var lastInCallUiRelayAnswerUptimeMs: Long = 0L
    private var lastInCallUiRelaySelectionUptimeMs: Long = 0L
    private var lastTelecomRelayForceLogUptimeMs: Long = 0L
    private var fakeMirrorAudioStartProbeDepth: Int = 0
    private var telecomRelayFeaturesInstalled: Boolean = false

    override fun handleLoadPackage(lpparam: XC_LoadPackage.LoadPackageParam) {
        if (!MiLinkPrivilegeHookPolicy.shouldHook(lpparam.packageName, lpparam.processName)) {
            return
        }

        log("loading hooks in package=${lpparam.packageName} process=${lpparam.processName}")
        if (MiLinkPrivilegeHookPolicy.shouldHookRuntime(lpparam.packageName, lpparam.processName)) {
            hookRuntimeCallingPackageCheck(lpparam.classLoader)
            hookRuntimeCallingUidCheck(lpparam.classLoader)
            hookMirrorHEVCEncoderRecovery()
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookMainService(lpparam.packageName, lpparam.processName)) {
            hookCastClientServiceCheck(lpparam.classLoader)
            hookMirrorHEVCEncoderRecovery()
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookDistributedHardware(lpparam.packageName, lpparam.processName)) {
            hookMirrorHEVCEncoderRecovery()
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookXiaomiMirror(lpparam.packageName, lpparam.processName)) {
            hookMirrorCallProviderAccessCheck(lpparam.classLoader)
            hookMirrorRemoteExperiment(lpparam.classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookMiConnectService(lpparam.packageName, lpparam.processName)) {
            hookMiConnectNetworkingPermission(lpparam.classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookInCallUi(lpparam.packageName, lpparam.processName)) {
            hookInCallUiRelayExperiment(lpparam.classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookAndroidPhone(lpparam.packageName, lpparam.processName)) {
            hookAndroidPhoneRelayServices(lpparam.classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookTelecomSystem(lpparam.packageName, lpparam.processName)) {
            hookTelecomRelayFeatures(lpparam.classLoader, "handleLoadPackage")
        }
    }

    private fun hookRuntimeCallingPackageCheck(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                MILINK_PRIVILEGED_PACKAGE_MANAGER,
                classLoader,
                "e",
                Context::class.java,
                String::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val callerPackage = param.args.getOrNull(1) as? String
                        if (MiLinkPrivilegeHookPolicy.isAllowedCallerPackage(callerPackage)) {
                            param.setResult(true)
                            log("allowed provider callerPackage=$callerPackage")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook provider package check: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookRuntimeCallingUidCheck(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                MILINK_PRIVILEGED_PACKAGE_MANAGER,
                classLoader,
                "d",
                Context::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val context = param.args.getOrNull(0) as? Context ?: return
                        val packages = context.packageManager.getPackagesForUid(Binder.getCallingUid())
                        if (MiLinkPrivilegeHookPolicy.hasAllowedCallerPackage(packages)) {
                            param.setResult(true)
                            log("allowed binder callerUid=${Binder.getCallingUid()}")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook binder uid check: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookCastClientServiceCheck(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                MILINK_BASE_CLIENT_SERVICE,
                classLoader,
                "b",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val context = param.thisObject as? Context ?: return
                        val packages = context.packageManager.getPackagesForUid(Binder.getCallingUid())
                        if (MiLinkPrivilegeHookPolicy.hasAllowedCallerPackage(packages)) {
                            param.setResult(null)
                            log("allowed cast service callerUid=${Binder.getCallingUid()}")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook cast client service check: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorCallProviderAccessCheck(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CALL_PROVIDER,
                classLoader,
                "g",
                Integer.TYPE,
                String::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val callerUid = param.args.getOrNull(0) as? Int ?: return
                        val method = param.args.getOrNull(1) as? String
                        if (!MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod(method)) {
                            return
                        }
                        val context = (param.thisObject as? ContentProvider)?.context ?: return
                        val packages = context.packageManager.getPackagesForUid(callerUid)
                        if (MiLinkPrivilegeHookPolicy.hasAllowedCallerPackage(packages)) {
                            param.setResult(null)
                            log("allowed mirror call provider method=$method callerUid=$callerUid")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror call provider check: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMiConnectNetworkingPermission(classLoader: ClassLoader) {
        hookMiConnectPermissionChecker(
            classLoader = classLoader,
            signature = arrayOf(Context::class.java)
        )
        hookMiConnectPermissionChecker(
            classLoader = classLoader,
            signature = arrayOf(Context::class.java, String::class.java)
        )
        hookMiConnectPermissionChecker(
            classLoader = classLoader,
            signature = arrayOf(Context::class.java, String::class.java, String::class.java)
        )
        hookMiConnectPermissionChecker(
            classLoader = classLoader,
            signature = arrayOf(Context::class.java, String::class.java, String::class.java, String::class.java)
        )
    }

    private fun hookMiConnectPermissionChecker(classLoader: ClassLoader, signature: Array<Class<*>>) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                MI_CONNECT_PERMISSION_CHECKER,
                classLoader,
                "checkPermissions",
                *signature,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val context = param.args.getOrNull(0) as? Context ?: return
                        val requestedPackage = param.args.getOrNull(1) as? String
                        val permission = param.args.getOrNull(2) as? String
                        val serviceId = param.args.getOrNull(3) as? String
                        val callerUid = Binder.getCallingUid()
                        val packages = context.packageManager.getPackagesForUid(callerUid)
                        if (MiLinkPrivilegeHookPolicy.isAllowedMiConnectCallerPackage(requestedPackage, packages)) {
                            param.setResult(0)
                            log(
                                "allowed mi_connect networking permission callerUid=$callerUid " +
                                    "requestedPackage=${requestedPackage ?: "-"} " +
                                    "permission=${permission ?: "-"} serviceId=${serviceId ?: "-"}"
                            )
                        }
                    }
                }
            )
        }.onFailure { error ->
            log(
                "failed to hook mi_connect permission checker args=${signature.size}: " +
                    "${error.javaClass.simpleName}: ${error.message}"
            )
        }
    }

    private fun hookMirrorRemoteExperiment(classLoader: ClassLoader) {
        hookMirrorRemoteProviderResults(classLoader)
        hookMirrorTerminalLookup(classLoader)
        hookMirrorDeviceTypeChecks(classLoader)
        hookMirrorTerminalMissingGuard(classLoader)
        hookMirrorUsingPadOverride(classLoader)
        hookMirrorScreenRouteDiagnostics(classLoader)
        hookMirrorAudioStartGuard(classLoader)
        hookMirrorPlainAudioRelay(classLoader)
    }

    private fun hookInCallUiRelayExperiment(classLoader: ClassLoader) {
        hookInCallUiCallRelayExtras(classLoader)
        hookInCallUiRelayHelpers(classLoader)
        hookInCallUiRelayDeviceList(classLoader)
        hookInCallUiRelaySelection(classLoader)
    }

    private fun hookInCallUiCallRelayExtras(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_CALL,
                classLoader,
                "getCallExtra",
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        if (!shouldForceInCallUiRelay()) {
                            return
                        }
                        param.result = fakeInCallUiCallExtras(param.result as? Bundle)
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI call extras: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_CALL,
                classLoader,
                "getRelayExtra",
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        if (!shouldForceInCallUiRelay()) {
                            return
                        }
                        param.result = fakeInCallUiRelayExtras(param.result as? Bundle)
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI relay extras: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_CALL,
                classLoader,
                "isCallRelayed",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (shouldForceInCallUiRelay()) {
                            param.setResult(true)
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI isCallRelayed: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_CALL,
                classLoader,
                "isRelayCall",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (shouldForceInCallUiRelay()) {
                            param.setResult(true)
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI isRelayCall: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_CALL,
                classLoader,
                "updateRelay",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (shouldForceInCallUiRelay()) {
                            log("InCallUI fake relay update call=${param.thisObject?.javaClass?.name.orEmpty()}")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI updateRelay: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookInCallUiRelayHelpers(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_RELAY_UTILS,
                classLoader,
                "getCallRelayAnswered",
                findTargetClass(classLoader, INCALLUI_CALL),
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (shouldForceInCallUiRelay()) {
                            param.setResult(true)
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI getCallRelayAnswered: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_RELAY_UTILS,
                classLoader,
                "getCallRelayed",
                findTargetClass(classLoader, INCALLUI_CALL),
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (shouldForceInCallUiRelay()) {
                            param.setResult(true)
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI getCallRelayed: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_RELAY_UTILS,
                classLoader,
                "getDeviceIdRelayAnswered",
                findTargetClass(classLoader, INCALLUI_CALL),
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (shouldForceInCallUiRelay()) {
                            param.setResult(MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI getDeviceIdRelayAnswered: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookInCallUiRelayDeviceList(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_RELAY_PRESENTER,
                classLoader,
                "getDeviceIdLists",
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        if (!shouldOfferInCallUiRelay()) {
                            return
                        }
                        val updated = fakeRelayDeviceIdList(param.result as? List<*>)
                        param.result = updated
                        log("InCallUI fake relay device id appended size=${updated.size}")
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI relay device list: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookInCallUiRelaySelection(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_RELAY_PRESENTER,
                classLoader,
                "relayAnswer",
                java.lang.Boolean.TYPE,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val relaySelected = param.args.getOrNull(0) as? Boolean ?: return
                        if (!relaySelected || !shouldOfferInCallUiRelay() || shouldForceInCallUiRelay()) {
                            return
                        }
                        notifyEdgeLinkRelaySelected("incallui_relayAnswer", param.thisObject)
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI relay selection: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookInCallUiRelayForeground(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_INCALL_PRESENTER,
                classLoader,
                "showInCall",
                java.lang.Boolean.TYPE,
                java.lang.Boolean.TYPE,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceInCallUiRelay()) {
                            return
                        }
                        forceInCallUiRelayAnswer(param.thisObject, "showInCall")
                        param.setResult(null)
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI showInCall: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_INCALL_PRESENTER,
                classLoader,
                "bringToForeground",
                java.lang.Boolean.TYPE,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceInCallUiRelay()) {
                            return
                        }
                        forceInCallUiRelayAnswer(param.thisObject, "bringToForeground")
                        param.setResult(null)
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI bringToForeground: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                INCALLUI_INCALL_PRESENTER,
                classLoader,
                "shouldStartActivity",
                findTargetClass(classLoader, INCALLUI_CALL),
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceInCallUiRelay()) {
                            return
                        }
                        forceInCallUiRelayAnswer(param.thisObject, "shouldStartActivity")
                        param.setResult(null)
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook InCallUI shouldStartActivity: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookAndroidPhoneRelayServices(classLoader: ClassLoader) {
        hookAndroidPhoneRelayDeviceList(
            classLoader = classLoader,
            className = ANDROID_PHONE_RELAY_SERVICE_BINDER,
            methodName = "getRelayDeviceIds",
            label = "RelayService"
        )
        hookAndroidPhoneRelayDeviceList(
            classLoader = classLoader,
            className = ANDROID_PHONE_RELAY_STATE_SERVICE_BINDER,
            methodName = "getSynergyDeviceList",
            label = "RelayStateService"
        )
    }

    private fun hookAndroidPhoneRelayDeviceList(
        classLoader: ClassLoader,
        className: String,
        methodName: String,
        label: String
    ) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                className,
                classLoader,
                methodName,
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        if (!shouldOfferAndroidPhoneRelay()) {
                            return
                        }
                        val updated = fakeRelayDeviceIdList(param.result as? List<*>)
                        param.result = updated
                        log("Android phone fake relay list label=$label size=${updated.size}")
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook Android phone relay list label=$label: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookTelecomRelayFeatures(classLoader: ClassLoader, source: String) {
        if (telecomRelayFeaturesInstalled) {
            return
        }
        val relayInstalled = hookTelecomRelayBooleanMethod(classLoader, "isRelayCall")
        val relayForPhoneInstalled = hookTelecomRelayBooleanMethod(classLoader, "isRelayCallForPhone")
        telecomRelayFeaturesInstalled = relayInstalled && relayForPhoneInstalled
        if (telecomRelayFeaturesInstalled) {
            log("Telecom relay feature hooks installed source=$source")
        }
    }

    private fun hookTelecomRelayBooleanMethod(
        classLoader: ClassLoader,
        methodName: String
    ): Boolean =
        runCatching {
            XposedHelpers.findAndHookMethod(
                TELECOM_SIMPLE_FEATURES,
                classLoader,
                methodName,
                findTargetClass(classLoader, TELECOM_CALL),
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceTelecomRelay()) {
                            return
                        }
                        param.setResult(true)
                        logTelecomRelayForced(methodName)
                    }
                }
            )
            log("Telecom relay feature hook installed method=$methodName")
            true
        }.getOrElse { error ->
            log("failed to hook Telecom $methodName: ${error.javaClass.simpleName}: ${error.message}")
            false
        }

    private fun logTelecomRelayForced(methodName: String) {
        val now = SystemClock.uptimeMillis()
        if (now - lastTelecomRelayForceLogUptimeMs < TELECOM_RELAY_FORCE_LOG_THROTTLE_MS) {
            return
        }
        lastTelecomRelayForceLogUptimeMs = now
        log("Telecom force relay method=$methodName")
    }

    private fun hookMirrorRemoteProviderResults(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CALL_PROVIDER,
                classLoader,
                "call",
                String::class.java,
                String::class.java,
                Bundle::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val mode = currentFakeMirrorProviderMode() ?: return
                        val method = param.args.getOrNull(0) as? String ?: return
                        if (method == "queryRemoteDevices" || method == "queryRemoteDevice") {
                            val terminal = prepareFakeMirrorTerminal(classLoader, mode)
                            maybeAttachFakeMirrorCallFlow(classLoader, mode, terminal)
                        }
                    }

                    override fun afterHookedMethod(param: MethodHookParam) {
                        val mode = currentFakeMirrorProviderMode() ?: return
                        val method = param.args.getOrNull(0) as? String ?: return
                        val extras = param.args.getOrNull(2) as? Bundle
                        when (method) {
                            "queryRemoteDevices" -> appendFakeMirrorRemoteResult(
                                classLoader = classLoader,
                                mode = mode,
                                extras = extras,
                                param = param
                            )

                            "queryRemoteDevice" -> replaceFakeMirrorRemoteResult(
                                classLoader = classLoader,
                                mode = mode,
                                extras = extras,
                                param = param
                            )
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror remote provider results: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun appendFakeMirrorRemoteResult(
        classLoader: ClassLoader,
        mode: String,
        extras: Bundle?,
        param: XC_MethodHook.MethodHookParam
    ) {
        val manufacturer = extras?.getString("remoteDeviceManufacturer")
        val platform = extras?.getString("device_platform")
        if (!MiLinkPrivilegeHookPolicy.shouldIncludeFakeMirrorRemote(mode, manufacturer, platform)) {
            return
        }
        val bundle = (param.getResult() as? Bundle) ?: Bundle().also { param.setResult(it) }
        bundle.setClassLoader(classLoader)
        val fakeRemote = createFakeMirrorRemoteInfo(classLoader, mode) ?: return
        @Suppress("DEPRECATION")
        val devices = bundle.getParcelableArrayList<Parcelable>("remoteDevices") ?: ArrayList()
        if (devices.none { device -> readRemoteDeviceId(device) == MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID }) {
            devices.add(fakeRemote)
        }
        bundle.putParcelableArrayList("remoteDevices", devices)
        log("mirror fake remote injected mode=$mode manufacturer=${manufacturer.orEmpty()} platform=${platform.orEmpty()}")
    }

    private fun replaceFakeMirrorRemoteResult(
        classLoader: ClassLoader,
        mode: String,
        extras: Bundle?,
        param: XC_MethodHook.MethodHookParam
    ) {
        val requestedId = extras?.getString("remoteDeviceId")
        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(requestedId)) {
            return
        }
        val fakeRemote = createFakeMirrorRemoteInfo(classLoader, mode) ?: return
        param.setResult(Bundle().apply {
            setClassLoader(classLoader)
            putParcelable("remoteDevice", fakeRemote)
        })
        log("mirror fake remote single result mode=$mode")
    }

    private fun hookMirrorTerminalLookup(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CONNECTION_MANAGER,
                classLoader,
                "t0",
                String::class.java,
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        if (param.getResult() != null) {
                            return
                        }
                        val mode = currentFakeMirrorProviderMode() ?: return
                        val deviceId = param.args.getOrNull(0) as? String
                        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                            return
                        }
                        if (shouldForceMirrorSourceRoute()) {
                            val terminal = prepareFakeMirrorSourceTerminal(classLoader)
                            param.setResult(terminal)
                            log(
                                "mirror fake terminal lookup sourceRole=mac " +
                                    "platform=${mirrorTerminalPlatform(terminal)} " +
                                    "ip=${mirrorTerminalIp(terminal)}"
                            )
                            return
                        }
                        val terminal = prepareFakeMirrorTerminal(classLoader, mode)
                        maybeAttachFakeMirrorCallFlow(classLoader, mode, terminal)
                        param.setResult(terminal)
                        log("mirror fake terminal lookup mode=$mode")
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror terminal lookup: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorDeviceTypeChecks(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_FUSION_UTILS,
                classLoader,
                "G",
                String::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val mode = currentFakeMirrorProviderMode() ?: return
                        val deviceId = param.args.getOrNull(0) as? String
                        if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId) &&
                            shouldForceMirrorSourceRoute()
                        ) {
                            param.setResult(false)
                            log("mirror fake source route rejected AndroidPad identity")
                            return
                        }
                        if (mode == "pad" && MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                            param.setResult(true)
                            log("mirror fake remote accepted as AndroidPad")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror pad identity check: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_FUSION_UTILS,
                classLoader,
                "D",
                String::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val deviceId = param.args.getOrNull(0) as? String
                        if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId) &&
                            shouldForceMirrorSourceRoute()
                        ) {
                            param.setResult(true)
                            log("mirror fake source route accepted as PC")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror PC identity check: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_FUSION_UTILS,
                classLoader,
                "E",
                String::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val deviceId = param.args.getOrNull(0) as? String
                        if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId) &&
                            shouldForceMirrorSourceRoute()
                        ) {
                            param.setResult(true)
                            log("mirror fake source route accepted as Mac")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror Mac identity check: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_FUSION_UTILS,
                classLoader,
                "w",
                String::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val mode = currentFakeMirrorProviderMode() ?: return
                        val deviceId = param.args.getOrNull(0) as? String
                        if (mode == "car" && MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                            param.setResult(true)
                            log("mirror fake remote accepted as AndroidPadCar")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror car identity check: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorTerminalMissingGuard(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_FUSION_UTILS,
                classLoader,
                "L",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceMirrorScreenTerminalPresent()) {
                            return
                        }
                        param.setResult(false)
                        val now = SystemClock.uptimeMillis()
                        if (now - lastFakeMirrorTerminalReadyUptimeMs >= FAKE_MIRROR_TERMINAL_READY_THROTTLE_MS) {
                            lastFakeMirrorTerminalReadyUptimeMs = now
                            log("mirror fake screen terminal missing override inactive")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror terminal missing guard: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorUsingPadOverride(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CALL_SERVICE,
                classLoader,
                "A",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (shouldForceMirrorPadIdentity()) {
                            param.setResult(true)
                            log("mirror fake pad using-pad override active")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror using-pad override: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorScreenRouteDiagnostics(classLoader: ClassLoader) {
        hookMirrorTerminalAddressOverride(classLoader)
        hookMirrorSourceRecoveryProvider(classLoader)
        hookMirrorSourceRouteOverrides(classLoader)
        hookMirrorSinkViewLifecycle(classLoader)
        hookMirrorSinkSurfaceCallback(classLoader)
        hookMirrorControlSinkStart(classLoader)
        hookMirrorControlSourceStart(classLoader)
        hookMirrorHEVCEncoderRecovery()
        hookMirrorControlNativeDiagnostics(classLoader)
        hookMirrorAdvConnectionLifecycle(classLoader)
        hookMirrorLyraGateDiagnostics(classLoader)
    }

    private fun hookMirrorTerminalAddressOverride(classLoader: ClassLoader) {
        runCatching {
            val terminalClass = findTargetClass(classLoader, XIAOMI_MIRROR_TERMINAL)
            terminalClass.methods
                .filter { method ->
                    method.name == "b" &&
                        method.parameterTypes.isEmpty() &&
                        InetAddress::class.java.isAssignableFrom(method.returnType)
                }
                .forEach { method ->
                    XposedBridge.hookMethod(
                        method,
                        object : XC_MethodHook() {
                            override fun beforeHookedMethod(param: MethodHookParam) {
                                if (!shouldForceMirrorScreenTerminalPresent()) {
                                    return
                                }
                                val terminalId = mirrorTerminalId(param.thisObject)
                                if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(terminalId)) {
                                    return
                                }
                                val peerIp = currentFakeMirrorRemotePeerIp() ?: DEFAULT_FAKE_MIRROR_PEER_IP
                                param.setResult(InetAddress.getByName(peerIp))
                                log("mirror fake terminal ip override terminalId=${terminalId.orEmpty()} peerIp=$peerIp")
                            }
                        }
                    )
                }
        }.onFailure { error ->
            log("failed to hook mirror terminal address: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorHEVCEncoderRecovery() {
        runCatching {
            XposedHelpers.findAndHookMethod(
                ANDROID_MEDIA_CODEC,
                null,
                "configure",
                MediaFormat::class.java,
                Surface::class.java,
                MediaCrypto::class.java,
                Integer.TYPE,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val format = param.args.getOrNull(0) as? MediaFormat ?: return
                        val flags = param.args.getOrNull(3) as? Int ?: return
                        if (!isHEVCEncoderFormat(format, flags) || !shouldForceMirrorSourceSession()) {
                            return
                        }
                        applyMirrorHEVCRecoveryFormat(format)
                    }

                    override fun afterHookedMethod(param: MethodHookParam) {
                        val codec = param.thisObject as? MediaCodec ?: return
                        val format = param.args.getOrNull(0) as? MediaFormat ?: return
                        val flags = param.args.getOrNull(3) as? Int ?: return
                        if (!isHEVCEncoderFormat(format, flags)) {
                            return
                        }
                        val state = MirrorHEVCEncoderState(
                            codec = codec,
                            codecId = System.identityHashCode(codec),
                            configuredUptimeMs = SystemClock.uptimeMillis(),
                            mime = readMediaFormatString(format, MediaFormat.KEY_MIME).orEmpty(),
                            formatSummary = format.toString()
                        )
                        liveMirrorHEVCEncoders[codec] = state
                        log(
                            "mirror hevc encoder configured process=${currentProcessName()} pid=${Process.myPid()} " +
                                "codec=${state.codecId} fakeSession=${shouldForceMirrorSourceSession()} format=${state.formatSummary}"
                        )
                    }
                }
            )
            XposedHelpers.findAndHookMethod(
                ANDROID_MEDIA_CODEC,
                null,
                "start",
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        val codec = param.thisObject as? MediaCodec ?: return
                        val state = liveMirrorHEVCEncoders[codec] ?: return
                        state.started = true
                        state.released = false
                        log("mirror hevc encoder started codec=${state.codecId} ageMs=${SystemClock.uptimeMillis() - state.configuredUptimeMs}")
                    }
                }
            )
            XposedHelpers.findAndHookMethod(
                ANDROID_MEDIA_CODEC,
                null,
                "stop",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val codec = param.thisObject as? MediaCodec ?: return
                        liveMirrorHEVCEncoders[codec]?.let { state ->
                            state.started = false
                            log("mirror hevc encoder stopping codec=${state.codecId}")
                        }
                    }
                }
            )
            XposedHelpers.findAndHookMethod(
                ANDROID_MEDIA_CODEC,
                null,
                "reset",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val codec = param.thisObject as? MediaCodec ?: return
                        liveMirrorHEVCEncoders.remove(codec)?.let { state ->
                            log("mirror hevc encoder reset codec=${state.codecId}")
                        }
                    }
                }
            )
            XposedHelpers.findAndHookMethod(
                ANDROID_MEDIA_CODEC,
                null,
                "release",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val codec = param.thisObject as? MediaCodec ?: return
                        liveMirrorHEVCEncoders.remove(codec)?.let { state ->
                            state.released = true
                            log("mirror hevc encoder released codec=${state.codecId}")
                        }
                    }
                }
            )
            log("mirror hevc encoder recovery hook installed")
        }.onFailure { error ->
            log("failed to hook mirror hevc encoder recovery: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorSourceRecoveryProvider(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CALL_PROVIDER,
                classLoader,
                "f",
                Integer.TYPE,
                String::class.java,
                String::class.java,
                String::class.java,
                Bundle::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val method = param.args.getOrNull(2) as? String
                        val extras = param.args.getOrNull(4) as? Bundle ?: return
                        val sourceRecoveryOnly = extras.booleanCompat("sourceRecoveryOnly")
                        val edgeLinkRecoveryMethod = method == "edgeLinkSourceRecovery"
                        val startShareRecovery = method == "startShare" && extras.booleanCompat("isStart")
                        if ((!edgeLinkRecoveryMethod && !startShareRecovery) ||
                            !extras.booleanCompat("recovery") ||
                            !MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(extras.getString("deviceId")) ||
                            !shouldForceMirrorScreenTerminalPresent()
                        ) {
                            return
                        }
                        armFakeMirrorSourceRouteWindow()
                        val reason = extras.getString("recoveryReason").orEmpty().ifBlank { "mac_stall" }
                        val attempt = extras.getString("recoveryAttempt").orEmpty().ifBlank { "?" }
                        val sourceResult = requestFakeMirrorSourceIDR("provider_recovery:$reason")
                        val codecResult = requestLiveMirrorHEVCEncoderSync("provider_recovery:$reason")
                        scheduleFakeMirrorSourceIDRBurst("provider_recovery:$reason")
                        log(
                            "mirror source recovery provider accepted " +
                                "method=$method sourceRecoveryOnly=$sourceRecoveryOnly " +
                                "attempt=$attempt reason=$reason $sourceResult $codecResult"
                        )
                        if (edgeLinkRecoveryMethod || sourceRecoveryOnly) {
                            param.result = Bundle().apply {
                                putBoolean("edgelinkRecoveryAccepted", true)
                                putBoolean("enable", true)
                                putInt("value", 0)
                                putString("recoveryMethod", method)
                                putString("recoveryReason", reason)
                                putString("recoveryAttempt", attempt)
                                putString("recoveryResult", "$sourceResult $codecResult")
                            }
                        }
                    }
                }
            )
            log("mirror source recovery provider hook installed")
        }.onFailure { error ->
            log("failed to hook mirror source recovery provider: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorSourceRouteOverrides(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_FUSION_UTILS,
                classLoader,
                "k",
                String::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val deviceId = param.args.getOrNull(0) as? String
                        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId) ||
                            !shouldForceMirrorScreenTerminalPresent()
                        ) {
                            return
                        }
                        val peerIp = currentFakeMirrorRemotePeerIp() ?: DEFAULT_FAKE_MIRROR_PEER_IP
                        val bindIp = if (shouldForceMirrorSourceRoute()) {
                            currentFakeMirrorSourceBindIp()
                        } else {
                            peerIp
                        }
                        param.setResult(bindIp)
                        log("mirror source endpoint override deviceId=$deviceId bindIp=$bindIp peerIp=$peerIp")
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror source endpoint: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_SHARE_PROCESSOR,
                classLoader,
                "n0",
                String::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val deviceId = param.args.getOrNull(0) as? String
                        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId) ||
                            !shouldForceMirrorScreenTerminalPresent()
                        ) {
                            return
                        }
                        startFakeMirrorSourceDisplay(classLoader, deviceId.orEmpty())
                        param.setResult(null)
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror source share processor: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun startFakeMirrorSourceDisplay(classLoader: ClassLoader, deviceId: String) {
        runCatching {
            armFakeMirrorSourceRouteWindow()
            val sourceTerminal = prepareFakeMirrorSourceTerminal(classLoader)
            ensureFakeMirrorCastBusinessDevice(classLoader, deviceId)
            val displayManagerClass = findTargetClass(classLoader, XIAOMI_MIRROR_DISPLAY_MANAGER)
            val displayHelperClass = findTargetClass(classLoader, XIAOMI_MIRROR_DISPLAY_HELPER)
            val configBuilder = displayHelperClass
                .getMethod("c", String::class.java, java.lang.Boolean.TYPE)
                .invoke(null, deviceId, false)
                ?: return@runCatching
            val config = configBuilder.javaClass.getMethod("a").invoke(configBuilder)
                ?: return@runCatching
            val callbackClass = findTargetClass(classLoader, XIAOMI_MIRROR_DISPLAY_CALLBACK)
            val manager = displayManagerClass.getMethod("C").invoke(null)
                ?: return@runCatching
            displayManagerClass.getMethod(
                "P0",
                config.javaClass,
                String::class.java,
                String::class.java,
                callbackClass
            ).invoke(manager, config, deviceId, null, null)
            val peerIp = currentFakeMirrorRemotePeerIp() ?: DEFAULT_FAKE_MIRROR_PEER_IP
            val peerPort = currentFakeMirrorRemotePeerPort() ?: DEFAULT_FAKE_MIRROR_PEER_PORT
            log(
                "mirror fake source display requested " +
                    "deviceId=$deviceId peer=$peerIp:$peerPort config=${identitySummary(config)} " +
                    " sourceTerminal=${identitySummary(sourceTerminal)} " +
                    "sourceTerminalPlatform=${mirrorTerminalPlatform(sourceTerminal)} " +
                    "sourceTerminalIp=${mirrorTerminalIp(sourceTerminal)}"
            )
        }.onFailure { error ->
            val cause = error.cause ?: error
            log("failed to start fake source display: ${cause.javaClass.simpleName}: ${cause.message}")
        }
    }

    private fun hookMirrorControlSourceStart(classLoader: ClassLoader) {
        runCatching {
            val sourceClass = findTargetClass(classLoader, XIAOMI_MIRROR_CONTROL_SOURCE)
            sourceClass.declaredConstructors.forEach { constructor ->
                XposedBridge.hookMethod(
                    constructor,
                    object : XC_MethodHook() {
                        override fun afterHookedMethod(param: MethodHookParam) {
                            if (!shouldForceMirrorSourceRoute() && !shouldForceMirrorScreenTerminalPresent()) {
                                return
                            }
                            armFakeMirrorSourceSessionWindow()
                            logMirrorSourceClassDiagnostics(param.thisObject)
                            configureFakeMirrorSourceAuth(param.thisObject)
                            overrideFakeMirrorSourcePort(param.thisObject)
                            rememberFakeMirrorControlSource(param.thisObject, "constructor")
                            val optionHandle = readMirrorControlSourceOptionHandle(param.thisObject)
                            if (optionHandle > 0L) {
                                fakeMirrorSourceOptionHandle = optionHandle
                            }
                            log(
                                "mirror source constructor configured " +
                                    "optionHandle=$optionHandle " +
                                    mirrorControlSourceSummary(param.thisObject)
                            )
                        }
                    }
                )
            }
            hookMirrorSourceOptionWrappers(sourceClass)
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CONTROL_SOURCE,
                classLoader,
                "startMirror",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceMirrorScreenTerminalPresent()) {
                            return
                        }
                        armFakeMirrorSourceSessionWindow()
                        enableMirrorNativeDebugLog(classLoader)
                        logMirrorSourceClassDiagnostics(param.thisObject)
                        configureFakeMirrorSourceAuth(param.thisObject)
                        overrideFakeMirrorSourcePort(param.thisObject)
                        rememberFakeMirrorControlSource(param.thisObject, "startMirror_enter")
                        val optionHandle = readMirrorControlSourceOptionHandle(param.thisObject)
                        if (optionHandle > 0L) {
                            fakeMirrorSourceOptionHandle = optionHandle
                        }
                        log(
                            "mirror source startMirror enter " +
                                "optionHandle=$optionHandle " +
                                mirrorControlSourceSummary(param.thisObject)
                        )
                    }

                    override fun afterHookedMethod(param: MethodHookParam) {
                        if (!shouldForceMirrorScreenTerminalPresent()) {
                            return
                        }
                        log(
                            "mirror source startMirror exit " +
                                "result=${param.getResult()} " +
                                mirrorControlSourceSummary(param.thisObject)
                        )
                    }
                }
            )
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CONTROL_SOURCE,
                classLoader,
                "closeMirror",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (lastFakeMirrorControlSource === param.thisObject) {
                            log(
                                "mirror source remembered instance closing " +
                                    mirrorControlSourceRecoverySummary(param.thisObject)
                            )
                            lastFakeMirrorControlSource = null
                            lastFakeMirrorControlSourceUptimeMs = 0L
                        }
                    }
                }
            )
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CONTROL_SOURCE,
                classLoader,
                "onDisplayConnected",
                Integer.TYPE,
                Integer.TYPE,
                Integer.TYPE,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceMirrorScreenTerminalPresent()) {
                            return
                        }
                        log(
                            "mirror source display connected " +
                                "width=${param.args.getOrNull(0)} " +
                                "height=${param.args.getOrNull(1)} " +
                                "flags=${param.args.getOrNull(2)} " +
                                mirrorControlSourceSummary(param.thisObject)
                        )
                    }
                }
            )
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CONTROL_SOURCE,
                classLoader,
                "onDisplayError",
                Integer.TYPE,
                Integer.TYPE,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceMirrorScreenTerminalPresent()) {
                            return
                        }
                        log(
                            "mirror source display error " +
                                "what=${param.args.getOrNull(0)} " +
                                "extra=${param.args.getOrNull(1)} " +
                                mirrorControlSourceSummary(param.thisObject)
                        )
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror source control: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorSourceOptionWrappers(sourceClass: Class<*>) {
        sourceClass.declaredMethods
            .filter { method -> method.name == "setMirrorSourceOption" }
            .forEach { method ->
                XposedBridge.hookMethod(
                    method,
                    object : XC_MethodHook() {
                        override fun beforeHookedMethod(param: MethodHookParam) {
                            if (!shouldForceMirrorSourceSession()) {
                                return
                            }
                            val option = (param.args.getOrNull(0) as? Int) ?: return
                            if (option == MIRROR_SOURCE_OPTION_ENCRYPT_AUTH_TYPE &&
                                fakeMirrorSourceAuthConfigDepth == 0
                            ) {
                                val oldValue = param.args.getOrNull(1)
                                if (oldValue != MIRROR_AUTHKEY_SOURCE_NONE) {
                                    param.args[1] = MIRROR_AUTHKEY_SOURCE_NONE
                                    log(
                                        "mirror source auth type wrapper forced " +
                                            "old=$oldValue new=$MIRROR_AUTHKEY_SOURCE_NONE"
                                    )
                                }
                            }
                            if (isMirrorSourceAuthOption(option)) {
                                log(
                                    "mirror source option wrapper enter " +
                                        "option=$option " +
                                        "args=${summarizeMirrorOptionArgs(param.args)} " +
                                        "sourceOptionHandle=${readMirrorControlSourceOptionHandle(param.thisObject)}"
                                )
                            }
                        }

                        override fun afterHookedMethod(param: MethodHookParam) {
                            if (!shouldForceMirrorSourceSession()) {
                                return
                            }
                            val option = (param.args.getOrNull(0) as? Int) ?: return
                            if (!isMirrorSourceAuthOption(option)) {
                                return
                            }
                            log(
                                "mirror source option wrapper exit " +
                                    "option=$option result=${param.getResult()} " +
                                    "sourceOptionHandle=${readMirrorControlSourceOptionHandle(param.thisObject)}"
                            )
                        }
                    }
                )
            }
    }

    private fun hookMirrorControlNativeDiagnostics(classLoader: ClassLoader) {
        runCatching {
            val mirrorControlClass = findTargetClass(classLoader, XIAOMI_MIRROR_CONTROL)
            logMirrorControlClassDiagnostics(mirrorControlClass)
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CONTROL,
                classLoader,
                "createSourceMirror",
                Any::class.java,
                String::class.java,
                Integer.TYPE,
                java.lang.Boolean.TYPE,
                Integer.TYPE,
                Integer.TYPE,
                Integer.TYPE,
                Integer.TYPE,
                java.lang.Long.TYPE,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceMirrorSourceSession()) {
                            return
                        }
                        val source = param.args.getOrNull(0)
                        configureFakeMirrorSourceAuth(source)
                        overrideFakeMirrorSourcePort(source)
                        rememberFakeMirrorControlSource(source, "native_createSourceMirror")
                        val optionHandle = (param.args.getOrNull(8) as? Number)?.toLong() ?: 0L
                        if (optionHandle > 0L) {
                            fakeMirrorSourceOptionHandle = optionHandle
                        }
                        log(
                            "mirror source native createSourceMirror enter " +
                                "ip=${param.args.getOrNull(1)} " +
                                "port=${param.args.getOrNull(2)} " +
                                "hevc=${param.args.getOrNull(3)} " +
                                "max=${param.args.getOrNull(4)}x${param.args.getOrNull(5)}@${param.args.getOrNull(6)} " +
                                "bitrate=${param.args.getOrNull(7)} " +
                                "optionHandle=$optionHandle " +
                                mirrorControlSourceSummary(source)
                        )
                    }

                    override fun afterHookedMethod(param: MethodHookParam) {
                        if (!shouldForceMirrorSourceSession()) {
                            return
                        }
                        log("mirror source native createSourceMirror exit handle=${param.getResult()}")
                    }
                }
            )
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CONTROL,
                classLoader,
                "startSourceMirror",
                java.lang.Long.TYPE,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (shouldForceMirrorSourceSession()) {
                            log("mirror source native startSourceMirror enter handle=${param.args.getOrNull(0)}")
                        }
                    }

                    override fun afterHookedMethod(param: MethodHookParam) {
                        if (shouldForceMirrorSourceSession()) {
                            log(
                                "mirror source native startSourceMirror exit " +
                                    "handle=${param.args.getOrNull(0)} result=${param.getResult()}"
                            )
                        }
                    }
                }
            )
            hookMirrorControlOptionInt(classLoader)
            hookMirrorControlOptionByte(classLoader)
            hookMirrorControlOptionString(classLoader)
        }.onFailure { error ->
            log("failed to hook mirror native diagnostics: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorControlOptionInt(classLoader: ClassLoader) {
        XposedHelpers.findAndHookMethod(
            XIAOMI_MIRROR_CONTROL,
            classLoader,
            "setMirrorOption",
            java.lang.Long.TYPE,
            Integer.TYPE,
            Integer.TYPE,
            object : XC_MethodHook() {
                override fun beforeHookedMethod(param: MethodHookParam) {
                    val handle = (param.args.getOrNull(0) as? Number)?.toLong() ?: 0L
                    val option = param.args.getOrNull(1) as? Int ?: return
                    if (shouldForceMirrorSourceSession() &&
                        option == MIRROR_SOURCE_OPTION_ENCRYPT_AUTH_TYPE &&
                        fakeMirrorSourceAuthConfigDepth == 0
                    ) {
                        val oldValue = param.args.getOrNull(2)
                        if (oldValue != MIRROR_AUTHKEY_SOURCE_NONE) {
                            param.args[2] = MIRROR_AUTHKEY_SOURCE_NONE
                            log(
                                "mirror source native auth type forced " +
                                    "handle=$handle old=$oldValue new=$MIRROR_AUTHKEY_SOURCE_NONE"
                            )
                        }
                    }
                    if (shouldLogMirrorSourceOption(handle, option)) {
                        log(
                            "mirror source native option int enter " +
                                "handle=$handle option=$option value=${param.args.getOrNull(2)}"
                        )
                    }
                }

                override fun afterHookedMethod(param: MethodHookParam) {
                    val handle = (param.args.getOrNull(0) as? Number)?.toLong() ?: 0L
                    val option = param.args.getOrNull(1) as? Int ?: return
                    if (shouldLogMirrorSourceOption(handle, option)) {
                        log(
                            "mirror source native option int exit " +
                                "handle=$handle option=$option result=${param.getResult()}"
                        )
                    }
                }
            }
        )
    }

    private fun hookMirrorControlOptionByte(classLoader: ClassLoader) {
        XposedHelpers.findAndHookMethod(
            XIAOMI_MIRROR_CONTROL,
            classLoader,
            "setMirrorOptionByte",
            java.lang.Long.TYPE,
            Integer.TYPE,
            ByteArray::class.java,
            Integer.TYPE,
            object : XC_MethodHook() {
                override fun beforeHookedMethod(param: MethodHookParam) {
                    val handle = (param.args.getOrNull(0) as? Number)?.toLong() ?: 0L
                    val option = param.args.getOrNull(1) as? Int ?: return
                    if (shouldLogMirrorSourceOption(handle, option)) {
                        log(
                            "mirror source native option byte enter " +
                                "handle=$handle option=$option " +
                                "bytes=${summarizeByteArray(param.args.getOrNull(2) as? ByteArray)} " +
                                "len=${param.args.getOrNull(3)}"
                        )
                    }
                }

                override fun afterHookedMethod(param: MethodHookParam) {
                    val handle = (param.args.getOrNull(0) as? Number)?.toLong() ?: 0L
                    val option = param.args.getOrNull(1) as? Int ?: return
                    if (shouldLogMirrorSourceOption(handle, option)) {
                        log(
                            "mirror source native option byte exit " +
                                "handle=$handle option=$option result=${param.getResult()}"
                        )
                    }
                }
            }
        )
    }

    private fun hookMirrorControlOptionString(classLoader: ClassLoader) {
        XposedHelpers.findAndHookMethod(
            XIAOMI_MIRROR_CONTROL,
            classLoader,
            "setMirrorOptionString",
            java.lang.Long.TYPE,
            Integer.TYPE,
            String::class.java,
            object : XC_MethodHook() {
                override fun beforeHookedMethod(param: MethodHookParam) {
                    val handle = (param.args.getOrNull(0) as? Number)?.toLong() ?: 0L
                    val option = param.args.getOrNull(1) as? Int ?: return
                    if (shouldLogMirrorSourceOption(handle, option)) {
                        log(
                            "mirror source native option string enter " +
                                "handle=$handle option=$option value=${sanitizeMirrorFieldValue(param.args.getOrNull(2) as? String)}"
                        )
                    }
                }

                override fun afterHookedMethod(param: MethodHookParam) {
                    val handle = (param.args.getOrNull(0) as? Number)?.toLong() ?: 0L
                    val option = param.args.getOrNull(1) as? Int ?: return
                    if (shouldLogMirrorSourceOption(handle, option)) {
                        log(
                            "mirror source native option string exit " +
                                "handle=$handle option=$option result=${param.getResult()}"
                        )
                    }
                }
            }
        )
    }

    private fun enableMirrorNativeDebugLog(classLoader: ClassLoader) {
        if (!shouldForceMirrorSourceSession()) {
            return
        }
        runCatching {
            val logManagerClass = findTargetClass(classLoader, XIAOMI_MIRROR_NATIVE_LOG_MANAGER)
            val singleton = logManagerClass.getMethod("a").invoke(null) ?: return@runCatching
            singleton.javaClass.getMethod("b").invoke(singleton)
            log("mirror native debug log enabled")
        }.onFailure { error ->
            log("failed to enable mirror native debug log: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun armFakeMirrorSourceRouteWindow() {
        val now = SystemClock.uptimeMillis()
        fakeMirrorSourceRouteUntilUptimeMs = now + FAKE_MIRROR_SOURCE_ROUTE_WINDOW_MS
        fakeMirrorSourceSessionUntilUptimeMs = now + FAKE_MIRROR_SOURCE_SESSION_WINDOW_MS
    }

    private fun armFakeMirrorSourceSessionWindow() {
        fakeMirrorSourceSessionUntilUptimeMs =
            SystemClock.uptimeMillis() + FAKE_MIRROR_SOURCE_SESSION_WINDOW_MS
    }

    private fun configureFakeMirrorSourceAuth(source: Any?) {
        if (!shouldForceMirrorSourceSession() || source == null) {
            return
        }
        fakeMirrorSourceAuthConfigDepth += 1
        runCatching {
            val optionHandle = readMirrorControlSourceOptionHandle(source)
            if (optionHandle > 0L) {
                fakeMirrorSourceOptionHandle = optionHandle
            }
            source.javaClass
                .getMethod("setMirrorSourceOption", Integer.TYPE, Integer.TYPE)
                .invoke(source, MIRROR_SOURCE_OPTION_ENCRYPT_AUTH_TYPE, MIRROR_AUTHKEY_SOURCE_NONE)
            source.javaClass
                .getMethod("setMirrorSourceOption", Integer.TYPE, Integer.TYPE)
                .invoke(source, MIRROR_OPTION_ENCRYPT_TRANS_BY_MIPLAY, 0)
            log(
                "mirror source external rtsp auth configured " +
                    "optionHandle=$optionHandle " +
                    "authType=$MIRROR_AUTHKEY_SOURCE_NONE " +
                    "auth=disabled_for_screen_route"
            )
        }.onFailure { error ->
            log("failed to configure mirror source auth: ${error.javaClass.simpleName}: ${error.message}")
        }.also {
            fakeMirrorSourceAuthConfigDepth -= 1
        }
    }

    private fun overrideFakeMirrorSourcePort(source: Any?) {
        if (!shouldForceMirrorSourceSession()) {
            return
        }
        val currentIp = readReflectiveStringFieldAny(source, "ip")
        val expectedIp = currentFakeMirrorSourceBindIp()
        if (currentIp != expectedIp) {
            return
        }
        val targetPort = currentFakeMirrorRemotePeerPort() ?: DEFAULT_FAKE_MIRROR_PEER_PORT
        val currentPort = readReflectiveFieldAny(source, "port") as? Int
        if (currentPort == targetPort) {
            return
        }
        val wrote = writeReflectiveIntFieldAny(source, targetPort, "port")
        log("mirror source port override ip=$expectedIp old=${currentPort ?: -1} new=$targetPort wrote=$wrote")
    }

    private fun rememberFakeMirrorControlSource(source: Any?, reason: String) {
        if (source == null || !shouldForceMirrorSourceSession()) {
            return
        }
        lastFakeMirrorControlSource = source
        lastFakeMirrorControlSourceUptimeMs = SystemClock.uptimeMillis()
        log("mirror source remembered reason=$reason ${mirrorControlSourceRecoverySummary(source)}")
    }

    private fun requestFakeMirrorSourceIDR(reason: String): String {
        val source = lastFakeMirrorControlSource
            ?: return "source=missing callback=false native=null ageMs=-1"
        val ageMs = SystemClock.uptimeMillis() - lastFakeMirrorControlSourceUptimeMs
        var callbackResult = false
        var nativeResult: Boolean? = null
        val callbackError = runCatching {
            source.javaClass.getMethod("requestEncodeIDRFrame").invoke(source)
            callbackResult = true
        }.exceptionOrNull()
        val nativeError = runCatching {
            nativeResult = source.javaClass.getMethod("requestIDREncodeMeidaCodec")
                .invoke(source) as? Boolean
        }.exceptionOrNull()
        val summary = "source=${identitySummary(source)} ageMs=$ageMs " +
            "callback=$callbackResult native=${nativeResult?.toString() ?: "null"} " +
            "handler=${readReflectiveFieldAny(source, "mirrorHandler") ?: -1L} " +
            "option=${readMirrorControlSourceOptionHandle(source)}"
        log(
            "mirror source idr requested reason=$reason $summary " +
                "callbackError=${callbackError?.javaClass?.simpleName ?: "none"} " +
                "nativeError=${nativeError?.javaClass?.simpleName ?: "none"}"
        )
        return summary
    }

    private fun requestLiveMirrorHEVCEncoderSync(reason: String): String {
        val now = SystemClock.uptimeMillis()
        var candidates = 0
        var requested = 0
        var throttled = 0
        val failures = ArrayList<String>()
        val states = synchronized(liveMirrorHEVCEncoders) {
            liveMirrorHEVCEncoders.values.toList()
        }
        states.forEach { state ->
            if (!state.started || state.released) {
                return@forEach
            }
            candidates += 1
            if (now - state.lastSyncRequestUptimeMs < MIRROR_HEVC_SYNC_REQUEST_THROTTLE_MS) {
                throttled += 1
                return@forEach
            }
            state.lastSyncRequestUptimeMs = now
            val result = runCatching {
                val params = Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                }
                state.codec.setParameters(params)
            }
            if (result.isSuccess) {
                requested += 1
                log(
                    "mirror hevc encoder sync requested reason=$reason codec=${state.codecId} " +
                        "ageMs=${now - state.configuredUptimeMs} format=${state.formatSummary}"
                )
            } else {
                val error = result.exceptionOrNull()
                failures += "${state.codecId}:${error?.javaClass?.simpleName ?: "error"}"
            }
        }
        return "codecSync=candidates:$candidates requested:$requested throttled:$throttled failures:${failures.joinToString(",")}"
    }

    private fun scheduleFakeMirrorSourceIDRBurst(reason: String) {
        val source = lastFakeMirrorControlSource ?: return
        val handler = Handler(Looper.getMainLooper())
        longArrayOf(650L).forEach { delayMs ->
            handler.postDelayed(
                {
                    if (lastFakeMirrorControlSource === source && shouldForceMirrorScreenTerminalPresent()) {
                        requestFakeMirrorSourceIDR("$reason:burst_${delayMs}ms")
                        requestLiveMirrorHEVCEncoderSync("$reason:burst_${delayMs}ms")
                    }
                },
                delayMs
            )
        }
    }

    private fun mirrorControlSourceRecoverySummary(source: Any?): String {
        val ageMs = if (lastFakeMirrorControlSource === source && lastFakeMirrorControlSourceUptimeMs > 0L) {
            SystemClock.uptimeMillis() - lastFakeMirrorControlSourceUptimeMs
        } else {
            -1L
        }
        return mirrorControlSourceSummary(source) + " rememberedAgeMs=$ageMs"
    }

    private fun hookMirrorSinkViewLifecycle(classLoader: ClassLoader) {
        runCatching {
            val sinkViewClass = findTargetClass(classLoader, XIAOMI_MIRROR_SINK_VIEW)
            val w0Methods = sinkViewClass.declaredMethods
                .filter { method -> method.name == "w0" }
            val z0Methods = sinkViewClass.declaredMethods
                .filter { method -> method.name == "z0" }
            val j1Methods = sinkViewClass.declaredMethods
                .filter { method -> method.name == "j1" }
            val e1Methods = sinkViewClass.declaredMethods
                .filter { method ->
                    method.name == "e1" && method.parameterTypes.size == 1
                }
            val attachedMethods = sinkViewClass.declaredMethods
                .filter { method ->
                    method.name == "onAttachedToWindow" && method.parameterTypes.isEmpty()
                }
                .ifEmpty {
                    listOfNotNull(
                        runCatching {
                            View::class.java.getDeclaredMethod("onAttachedToWindow")
                        }.getOrNull()
                    )
                }
            val detachedMethods = sinkViewClass.declaredMethods
                .filter { method ->
                    method.name == "onDetachedFromWindow" && method.parameterTypes.isEmpty()
                }
                .ifEmpty {
                    listOfNotNull(
                        runCatching {
                            View::class.java.getDeclaredMethod("onDetachedFromWindow")
                        }.getOrNull()
                    )
                }
            log(
                "mirror sink lifecycle hooks installing " +
                    "w0=${w0Methods.size} z0=${z0Methods.size} j1=${j1Methods.size} " +
                    "e1=${e1Methods.size} attach=${attachedMethods.size} detach=${detachedMethods.size}"
            )
            attachedMethods.forEach { method ->
                    XposedBridge.hookMethod(
                        method,
                        object : XC_MethodHook() {
                            override fun afterHookedMethod(param: MethodHookParam) {
                                if (!sinkViewClass.isInstance(param.thisObject)) {
                                    return
                                }
                                val deviceId = mirrorSinkDeviceId(param.thisObject)
                                if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                                    log("mirror sink attached ${mirrorSinkStateSummary(param.thisObject, deviceId)}")
                                    scheduleFakeMirrorSinkRoute(classLoader, param.thisObject, deviceId)
                                }
                            }
                        }
                    )
                }
            detachedMethods.forEach { method ->
                    XposedBridge.hookMethod(
                        method,
                        object : XC_MethodHook() {
                            override fun beforeHookedMethod(param: MethodHookParam) {
                                if (!sinkViewClass.isInstance(param.thisObject)) {
                                    return
                                }
                                val deviceId = mirrorSinkDeviceId(param.thisObject)
                                if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                                    log("mirror sink detached ${mirrorSinkStateSummary(param.thisObject, deviceId)}")
                                    releaseFakeMirrorSinkSurface(param.thisObject)
                                }
                            }
                        }
                    )
                }
            w0Methods.forEach { method ->
                    XposedBridge.hookMethod(
                        method,
                        object : XC_MethodHook() {
                            override fun beforeHookedMethod(param: MethodHookParam) {
                                val deviceId = param.args.getOrNull(0) as? String
                                if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                                    log("mirror sink w0 enter ${mirrorSinkStateSummary(param.thisObject, deviceId)}")
                                }
                            }

                            override fun afterHookedMethod(param: MethodHookParam) {
                                val deviceId = param.args.getOrNull(0) as? String
                                    ?: mirrorSinkDeviceId(param.thisObject)
                                if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                                    log("mirror sink w0 exit ${mirrorSinkStateSummary(param.thisObject, deviceId)}")
                                    scheduleFakeMirrorSinkRoute(classLoader, param.thisObject, deviceId)
                                }
                            }
                        }
                    )
                }
            z0Methods.forEach { method ->
                    XposedBridge.hookMethod(
                        method,
                        object : XC_MethodHook() {
                            override fun afterHookedMethod(param: MethodHookParam) {
                                val deviceId = mirrorSinkDeviceId(param.thisObject)
                                if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                                    log("mirror sink z0 exit ${mirrorSinkStateSummary(param.thisObject, deviceId)}")
                                    scheduleFakeMirrorSinkRoute(classLoader, param.thisObject, deviceId)
                                }
                            }
                        }
                    )
                }
            j1Methods.forEach { method ->
                    XposedBridge.hookMethod(
                        method,
                        object : XC_MethodHook() {
                            override fun beforeHookedMethod(param: MethodHookParam) {
                                val deviceId = mirrorSinkDeviceId(param.thisObject)
                                if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                                    log("mirror sink j1 enter ${mirrorSinkStateSummary(param.thisObject, deviceId)}")
                                }
                            }

                            override fun afterHookedMethod(param: MethodHookParam) {
                                val deviceId = mirrorSinkDeviceId(param.thisObject)
                                if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                                    log("mirror sink j1 exit ${mirrorSinkStateSummary(param.thisObject, deviceId)}")
                                }
                            }
                        }
                    )
                }
            e1Methods.forEach { method ->
                    XposedBridge.hookMethod(
                        method,
                        object : XC_MethodHook() {
                            override fun beforeHookedMethod(param: MethodHookParam) {
                                val deviceId = mirrorSinkDeviceId(param.thisObject)
                                val callbackClose = param.args.getOrNull(0) as? Boolean ?: false
                                if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId) ||
                                    !shouldForceMirrorScreenTerminalPresent()
                                ) {
                                    return
                                }
                                log(
                                    "mirror sink e1 enter blocked=${!callbackClose} " +
                                        "callbackClose=$callbackClose " +
                                        mirrorSinkStateSummary(param.thisObject, deviceId)
                                )
                                if (!callbackClose) {
                                    scheduleFakeMirrorSinkRoute(classLoader, param.thisObject, deviceId)
                                    param.setResult(null)
                                }
                            }
                        }
                    )
                }
        }.onFailure { error ->
            log("failed to hook mirror sink lifecycle: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorSinkSurfaceCallback(classLoader: ClassLoader) {
        runCatching {
            val callbackClass = findTargetClass(classLoader, XIAOMI_MIRROR_SINK_VIEW_SURFACE_CALLBACK)
            XposedHelpers.findAndHookMethod(
                callbackClass.name,
                classLoader,
                "surfaceCreated",
                SurfaceHolder::class.java,
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        val sinkView = readReflectiveFieldAny(param.thisObject, "this$0")
                        val deviceId = mirrorSinkDeviceId(sinkView)
                        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                            return
                        }
                        val holderSurface = runCatching {
                            (param.args.getOrNull(0) as? SurfaceHolder)?.surface
                        }.getOrNull()
                        log(
                            "mirror sink surfaceCreated " +
                                "holderSurface=${holderSurface != null} " +
                                "holderSurfaceValid=${holderSurface?.isValid == true} " +
                                mirrorSinkStateSummary(sinkView, deviceId)
                        )
                        if (shouldForceMirrorScreenTerminalPresent()) {
                            releaseFakeMirrorSinkSurface(sinkView)
                            scheduleFakeMirrorSinkRoute(classLoader, sinkView, deviceId)
                        }
                    }
                }
            )
            XposedHelpers.findAndHookMethod(
                callbackClass.name,
                classLoader,
                "surfaceDestroyed",
                SurfaceHolder::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val sinkView = readReflectiveFieldAny(param.thisObject, "this$0")
                        val deviceId = mirrorSinkDeviceId(sinkView)
                        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                            return
                        }
                        log("mirror sink surfaceDestroyed ${mirrorSinkStateSummary(sinkView, deviceId)}")
                        releaseFakeMirrorSinkSurface(sinkView)
                    }
                }
            )
            log("mirror sink surface callback hooks installed")
        }.onFailure { error ->
            log("failed to hook mirror sink surface callback: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorControlSinkStart(classLoader: ClassLoader) {
        runCatching {
            val sinkClass = findTargetClass(classLoader, XIAOMI_MIRROR_CONTROL_SINK)
            val startMethods = sinkClass.declaredMethods.filter { method ->
                method.name == "startMirror" &&
                    method.parameterTypes.size == 5 &&
                    method.parameterTypes[1] == String::class.java &&
                    method.parameterTypes[2] == Integer.TYPE &&
                    method.parameterTypes[3] == java.lang.Boolean.TYPE &&
                    Surface::class.java.isAssignableFrom(method.parameterTypes[4])
            }
            startMethods.forEach { method ->
                XposedBridge.hookMethod(
                    method,
                    object : XC_MethodHook() {
                        override fun beforeHookedMethod(param: MethodHookParam) {
                            if (!shouldForceMirrorScreenTerminalPresent()) {
                                return
                            }
                            val remoteIp = param.args.getOrNull(1) as? String
                            val port = param.args.getOrNull(2) as? Int
                            val useTcp = param.args.getOrNull(3) as? Boolean
                            val surface = param.args.getOrNull(4) as? Surface
                            log(
                                "mirror control sink startMirror enter " +
                                    "remoteIp=${remoteIp.orEmpty()} " +
                                    "port=${port ?: -1} " +
                                    "useTcp=${useTcp?.toString() ?: "?"} " +
                                    "surface=${surface != null} " +
                                    "surfaceValid=${surface?.isValid == true}"
                            )
                        }

                        override fun afterHookedMethod(param: MethodHookParam) {
                            if (!shouldForceMirrorScreenTerminalPresent()) {
                                return
                            }
                            log("mirror control sink startMirror exit result=${param.getResult()}")
                        }
                    }
                )
            }
            log("mirror control sink start hooks installing count=${startMethods.size}")
        }.onFailure { error ->
            log("failed to hook mirror control sink start: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorAdvConnectionLifecycle(classLoader: ClassLoader) {
        runCatching {
            val terminalClass = findTargetClass(classLoader, XIAOMI_MIRROR_TERMINAL)
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CONNECTION_MANAGER,
                classLoader,
                "y0",
                terminalClass,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceMirrorScreenTerminalPresent()) {
                            return
                        }
                        val terminal = param.args.getOrNull(0)
                        val terminalId = mirrorTerminalId(terminal)
                        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(terminalId)) {
                            return
                        }
                        val ref = createSuccessfulMirrorAdvReference(classLoader) ?: return
                        param.setResult(ref)
                        log(
                            "mirror fake adv request override " +
                                "terminalId=${terminalId.orEmpty()} " +
                                "terminalIp=${mirrorTerminalIp(terminal)} " +
                                "ref=${identitySummary(ref)} " +
                                "state=${mirrorAdvState(ref)}"
                        )
                    }

                    override fun afterHookedMethod(param: MethodHookParam) {
                        val terminal = param.args.getOrNull(0)
                        val terminalId = mirrorTerminalId(terminal)
                        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(terminalId)) {
                            return
                        }
                        val ref = param.getResult()
                        log(
                            "mirror fake adv request " +
                                "terminalId=${terminalId.orEmpty()} " +
                                "terminalIp=${mirrorTerminalIp(terminal)} " +
                                "ref=${identitySummary(ref)} " +
                                "state=${mirrorAdvState(ref)}"
                        )
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror adv request: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            val advReferenceClass = findFirstTargetClass(
                classLoader,
                XIAOMI_MIRROR_ADV_CONNECTION_REFERENCE,
                XIAOMI_MIRROR_ADV_CONNECTION_REFERENCE_OBFUSCATED
            )
            XposedHelpers.findAndHookMethod(
                advReferenceClass.name,
                classLoader,
                "e",
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        if (shouldForceMirrorScreenTerminalPresent()) {
                            log("mirror adv reference success ref=${identitySummary(param.thisObject)}")
                        }
                    }
                }
            )
            XposedHelpers.findAndHookMethod(
                advReferenceClass.name,
                classLoader,
                "d",
                Integer.TYPE,
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        if (shouldForceMirrorScreenTerminalPresent()) {
                            val code = param.args.getOrNull(0) as? Int
                            log("mirror adv reference failure ref=${identitySummary(param.thisObject)} code=${code ?: -1}")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror adv reference: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun createSuccessfulMirrorAdvReference(classLoader: ClassLoader): Any? =
        runCatching {
            val advReferenceClass = findFirstTargetClass(
                classLoader,
                XIAOMI_MIRROR_ADV_CONNECTION_REFERENCE,
                XIAOMI_MIRROR_ADV_CONNECTION_REFERENCE_OBFUSCATED
            )
            val constructor = advReferenceClass.declaredConstructors.firstOrNull { constructor ->
                constructor.parameterTypes.size == 1
            } ?: return@runCatching null
            constructor.isAccessible = true
            val reference = constructor.newInstance(null)
            advReferenceClass.getMethod("e").invoke(reference)
            reference
        }.onFailure { error ->
            log("failed to create fake adv reference: ${error.javaClass.simpleName}: ${error.message}")
        }.getOrNull()

    private fun scheduleFakeMirrorSinkRoute(classLoader: ClassLoader, sinkView: Any?, deviceId: String?) {
        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId) ||
            !shouldForceMirrorScreenTerminalPresent() ||
            sinkView !is View
        ) {
            return
        }
        val delays = longArrayOf(0L, 120L, 450L, 900L, 1_600L, 2_500L, 4_000L)
        delays.forEach { delayMs ->
            sinkView.postDelayed(
                {
                    armFakeMirrorSinkRoute(classLoader, sinkView, deviceId.orEmpty(), delayMs)
                },
                delayMs
            )
        }
        log("mirror fake sink route scheduled deviceId=${deviceId.orEmpty()}")
    }

    private fun armFakeMirrorSinkRoute(
        classLoader: ClassLoader,
        sinkView: Any,
        deviceId: String,
        delayMs: Long
    ) {
        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId) ||
            !shouldForceMirrorScreenTerminalPresent()
        ) {
            return
        }
        runCatching {
            val mode = currentFakeMirrorRemoteMode() ?: "pad"
            var terminalWrite = false
            val terminal = readMirrorSinkTerminal(sinkView)
                ?: prepareFakeMirrorTerminal(classLoader, mode)?.also { fakeTerminal ->
                    terminalWrite = writeReflectiveFieldAny(sinkView, fakeTerminal, "o", "f10724o")
                }
            val isLyraWrite = writeReflectiveBooleanFieldAny(sinkView, false, "n", "f10723n")
            var advWrite = false
            val advReference = readMirrorSinkAdvReference(sinkView)
                ?.takeIf { mirrorAdvState(it) == "0" }
                ?: createSuccessfulMirrorAdvReference(classLoader)?.also { ref ->
                    advWrite = writeReflectiveFieldAny(sinkView, ref, "s", "f10733s")
                }
            val configSummary = configureFakeMirrorSinkConfig(sinkView)
            val surfaceSummary = ensureMirrorSinkSurface(sinkView)
            val peerPort = currentFakeMirrorRemotePeerPort() ?: DEFAULT_FAKE_MIRROR_PEER_PORT
            val hasInitOk = runCatching {
                sinkView.javaClass.getMethod("setHasInit", java.lang.Boolean.TYPE).invoke(sinkView, true)
                true
            }.getOrDefault(false)
            val currentPort = runCatching {
                sinkView.javaClass.getMethod("getPort").invoke(sinkView) as? Int
            }.getOrNull() ?: readMirrorSinkPort(sinkView) ?: 0
            var setPortOk = false
            var r0Ok = false
            if (currentPort != peerPort) {
                setPortOk = runCatching {
                    sinkView.javaClass.getMethod("setPort", Integer.TYPE).invoke(sinkView, peerPort)
                    true
                }.getOrDefault(false)
            } else {
                val displayType = readMirrorSinkDisplayType(sinkView) ?: 0
                r0Ok = runCatching {
                    sinkView.javaClass.getMethod("R0", Integer.TYPE).invoke(sinkView, displayType)
                    true
                }.getOrDefault(false)
            }
            log(
                "mirror fake sink route armed " +
                    "delayMs=$delayMs " +
                    "port=$peerPort " +
                    "terminalWrite=$terminalWrite " +
                    "lyraWrite=$isLyraWrite " +
                    "advWrite=$advWrite " +
                    "hasInit=$hasInitOk " +
                    "setPort=$setPortOk " +
                    "r0=$r0Ok " +
                    "$configSummary " +
                    "$surfaceSummary " +
                    "terminal=${identitySummary(terminal)} " +
                    "terminalId=${mirrorTerminalId(terminal).orEmpty()} " +
                    "terminalIp=${mirrorTerminalIp(terminal)} " +
                    "adv=${identitySummary(advReference)} " +
                    "advState=${mirrorAdvState(advReference)} " +
                    mirrorSinkStateSummary(sinkView, deviceId)
            )
        }.onFailure { error ->
            log("failed to arm fake sink route: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun ensureMirrorSinkSurface(sinkView: Any): String {
        val existing = readMirrorSinkSurface(sinkView) as? Surface
        if (existing != null && existing.isValid) {
            return "surfaceWrite=false surfaceValid=true surfaceSource=field"
        }
        val surfaceView = runCatching {
            sinkView.javaClass.getMethod("getSurfaceView").invoke(sinkView) as? View
        }.getOrNull()
        if (surfaceView != null) {
            runCatching { surfaceView.visibility = View.VISIBLE }
            runCatching { surfaceView.requestLayout() }
            runCatching { surfaceView.invalidate() }
        }
        val viewSummary =
            "surfaceViewAttached=${surfaceView?.isAttachedToWindow == true} " +
                "surfaceViewShown=${surfaceView?.isShown == true} " +
                "surfaceViewVisibility=${surfaceView?.visibility ?: -1}"
        val surface = runCatching {
            val holder = surfaceView?.javaClass?.getMethod("getHolder")?.invoke(surfaceView)
                ?: return@runCatching null
            holder.javaClass.getMethod("getSurface").invoke(holder) as? Surface
        }.getOrNull()
        val valid = surface?.isValid == true
        val wrote = if (surface != null && valid) {
            writeReflectiveFieldAny(sinkView, surface, "y", "f10744y")
        } else {
            false
        }
        if (wrote) {
            releaseFakeMirrorSinkSurface(sinkView)
            return "surfaceWrite=true surfaceValid=true surfaceSource=holder $viewSummary"
        }
        if (!shouldForceMirrorScreenTerminalPresent()) {
            return "surfaceWrite=false surfaceValid=$valid surfaceSource=holder $viewSummary"
        }
        val deviceId = mirrorSinkDeviceId(sinkView)
        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
            return "surfaceWrite=false surfaceValid=$valid surfaceSource=holder $viewSummary"
        }
        val fallback = createOrReuseFakeMirrorSinkSurface(sinkView)
        val fallbackWrote = writeReflectiveFieldAny(sinkView, fallback.surface, "y", "f10744y")
        return "surfaceWrite=$fallbackWrote " +
            "surfaceValid=${fallback.surface.isValid} " +
            "surfaceSource=fallback " +
            "holderSurface=${surface != null} " +
            "holderSurfaceValid=$valid " +
            viewSummary
    }

    private fun createOrReuseFakeMirrorSinkSurface(sinkView: Any): FakeMirrorSinkSurface {
        val key = System.identityHashCode(sinkView)
        fakeMirrorSinkSurfaces[key]?.takeIf { it.surface.isValid }?.let { existing ->
            return existing
        }
        fakeMirrorSinkSurfaces.remove(key)?.release()
        val (width, height) = fakeMirrorSinkSurfaceSize(sinkView)
        val texture = SurfaceTexture(0)
        texture.setDefaultBufferSize(width, height)
        val surface = Surface(texture)
        val fallback = FakeMirrorSinkSurface(texture, surface)
        fakeMirrorSinkSurfaces[key] = fallback
        log(
            "mirror fake sink fallback surface created " +
                "key=$key width=$width height=$height surfaceValid=${surface.isValid}"
        )
        return fallback
    }

    private fun releaseFakeMirrorSinkSurface(sinkView: Any?) {
        val key = System.identityHashCode(sinkView ?: return)
        val removed = fakeMirrorSinkSurfaces.remove(key) ?: return
        removed.release()
        log("mirror fake sink fallback surface released key=$key")
    }

    private fun fakeMirrorSinkSurfaceSize(sinkView: Any): Pair<Int, Int> {
        val config = runCatching {
            sinkView.javaClass.getMethod("getConfig").invoke(sinkView)
        }.getOrNull() ?: readReflectiveFieldAny(sinkView, "z", "f10748z")
        val width = (readReflectiveFieldAny(config, "b", "f14777b") as? Int)
            ?.takeIf { it in 1..8192 }
            ?: 1080
        val height = (readReflectiveFieldAny(config, "c", "f14778c") as? Int)
            ?.takeIf { it in 1..8192 }
            ?: 2400
        return width to height
    }

    private fun configureFakeMirrorSinkConfig(sinkView: Any): String {
        val config = runCatching {
            sinkView.javaClass.getMethod("getConfig").invoke(sinkView)
        }.getOrNull() ?: readReflectiveFieldAny(sinkView, "z", "f10748z") ?: return "config=missing"
        val screenWrite = writeReflectiveIntFieldAny(config, 0, "a", "f14776a")
        val widthWrite = writeReflectiveIntFieldAny(config, 1080, "b", "f14777b")
        val heightWrite = writeReflectiveIntFieldAny(config, 2400, "c", "f14778c")
        val aspectWrite = writeReflectiveFloatFieldAny(config, 2400f / 1080f, "d", "f14779d")
        val navWrite = writeReflectiveBooleanFieldAny(config, true, "e", "f14780e")
        val secureWrite = writeReflectiveBooleanFieldAny(config, false, "f", "f14781f")
        val landscapeWrite = writeReflectiveBooleanFieldAny(config, false, "g", "f14782g")
        val flippedWrite = writeReflectiveBooleanFieldAny(config, false, "h", "f14783h")
        val foldWrite = writeReflectiveBooleanFieldAny(config, false, "i", "f14784i")
        return "config=${identitySummary(config)} " +
            "configWrites=$screenWrite/$widthWrite/$heightWrite/$aspectWrite/" +
            "$navWrite/$secureWrite/$landscapeWrite/$flippedWrite/$foldWrite"
    }

    private fun hookMirrorLyraGateDiagnostics(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CAST_BUSINESS_WRAPPER,
                classLoader,
                "q",
                String::class.java,
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        val deviceId = param.args.getOrNull(0) as? String
                        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                            return
                        }
                        var lyraDevice = param.getResult()
                        if (lyraDevice == null && shouldForceMirrorScreenTerminalPresent()) {
                            lyraDevice = ensureFakeMirrorCastBusinessDevice(classLoader, deviceId.orEmpty())
                            if (lyraDevice != null) {
                                param.setResult(lyraDevice)
                            }
                        }
                        val trusted = runCatching {
                            lyraDevice?.javaClass?.getMethod("d")?.invoke(lyraDevice)
                        }.getOrNull()
                        log(
                            "mirror lyra q " +
                                "deviceId=${deviceId.orEmpty()} " +
                                "device=${identitySummary(lyraDevice)} " +
                                "trusted=${identitySummary(trusted)}"
                        )
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror lyra device lookup: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            val businessClass = findTargetClass(classLoader, XIAOMI_MIRROR_LYRA_BUSINESS)
            val channelMethods = businessClass.methods
                .filter { method ->
                    method.name == "l" &&
                        method.parameterTypes.size == 1 &&
                        method.parameterTypes[0] == String::class.java &&
                        method.returnType == java.lang.Boolean.TYPE
                }
            channelMethods.forEach { method ->
                XposedBridge.hookMethod(
                    method,
                    object : XC_MethodHook() {
                        override fun beforeHookedMethod(param: MethodHookParam) {
                            val deviceId = param.args.getOrNull(0) as? String
                            if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId) &&
                                shouldForceMirrorScreenTerminalPresent()
                            ) {
                                param.setResult(true)
                                log("mirror lyra channel exists override deviceId=$deviceId")
                            }
                        }

                        override fun afterHookedMethod(param: MethodHookParam) {
                            val deviceId = param.args.getOrNull(0) as? String
                            if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                                log("mirror lyra channel exists deviceId=$deviceId value=${param.getResult()}")
                            }
                        }
                    }
                )
            }
            log("mirror lyra channel hooks installing count=${channelMethods.size}")
        }.onFailure { error ->
            log("failed to hook mirror lyra channel check: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_LYRA_UTILS,
                classLoader,
                "K",
                String::class.java,
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        val deviceId = param.args.getOrNull(0) as? String
                        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                            return
                        }
                        val original = param.getResult() as? String
                        if (original.isNullOrBlank() && shouldForceMirrorScreenTerminalPresent()) {
                            val peerIp = currentFakeMirrorRemotePeerIp() ?: DEFAULT_FAKE_MIRROR_PEER_IP
                            param.setResult(peerIp)
                            log("mirror lyra remote ip override deviceId=$deviceId peerIp=$peerIp")
                        } else {
                            log("mirror lyra remote ip deviceId=$deviceId value=${original.orEmpty()}")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror lyra remote ip: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_LYRA_UTILS,
                classLoader,
                "p0",
                String::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val deviceId = param.args.getOrNull(0) as? String
                        if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId) &&
                            shouldForceMirrorScreenTerminalPresent()
                        ) {
                            param.setResult(true)
                            log("mirror lyra wlan ability override deviceId=$deviceId")
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror lyra wlan ability: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun ensureFakeMirrorCastBusinessDevice(classLoader: ClassLoader, deviceId: String): Any? =
        runCatching {
            val mirrorClass = findTargetClass(classLoader, XIAOMI_MIRROR_APPLICATION)
            val mirror = mirrorClass.getMethod("z").invoke(null) ?: return@runCatching null
            val castBusiness = mirrorClass.getMethod("p").invoke(mirror) ?: return@runCatching null
            val existing = castBusiness.javaClass.getMethod("g", String::class.java)
                .invoke(castBusiness, deviceId)
            if (existing != null) {
                return@runCatching existing
            }
            val trustedInfo = createFakeMirrorTrustedDeviceInfo(classLoader, deviceId)
                ?: return@runCatching null
            val trustedInfoClass = findTargetClass(classLoader, XIAOMI_CONTINUITY_TRUSTED_DEVICE_INFO)
            val added = runCatching {
                castBusiness.javaClass.getMethod("a", trustedInfoClass)
                    .invoke(castBusiness, trustedInfo) as? Boolean
            }.getOrDefault(false)
            val resolved = castBusiness.javaClass.getMethod("g", String::class.java)
                .invoke(castBusiness, deviceId)
            log(
                "mirror fake lyra device injected " +
                    "deviceId=$deviceId added=$added " +
                    "resolved=${identitySummary(resolved)} " +
                    "trusted=${trustedInfo}"
            )
            resolved
        }.onFailure { error ->
            log("failed to inject fake lyra device: ${error.javaClass.simpleName}: ${error.message}")
        }.getOrNull()

    private fun createFakeMirrorTrustedDeviceInfo(classLoader: ClassLoader, deviceId: String): Any? =
        runCatching {
            val trustedInfoClass = findTargetClass(classLoader, XIAOMI_CONTINUITY_TRUSTED_DEVICE_INFO)
            val trustedInfo = trustedInfoClass.getConstructor().newInstance()
            trustedInfoClass.getMethod("k", String::class.java).invoke(trustedInfo, deviceId)
            trustedInfoClass.getMethod("l", String::class.java)
                .invoke(trustedInfo, MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_NAME)
            trustedInfoClass.getMethod("m", Integer.TYPE)
                .invoke(trustedInfo, FAKE_MIRROR_TRUSTED_DEVICE_TYPE)
            writeReflectiveIntFieldAny(
                trustedInfo,
                FAKE_MIRROR_TRUSTED_MEDIUM_TYPES,
                "d",
                "f8997d"
            )
            writeReflectiveIntFieldAny(
                trustedInfo,
                FAKE_MIRROR_TRUSTED_TYPES,
                "e",
                "f8998e"
            )
            trustedInfo
        }.onFailure { error ->
            log("failed to create fake trusted device info: ${error.javaClass.simpleName}: ${error.message}")
        }.getOrNull()

    private fun maybeAttachFakeMirrorCallFlow(classLoader: ClassLoader, mode: String, terminal: Any?) {
        if (mode != "pad" || terminal == null || !shouldAttachFakeMirrorTerminal()) {
            return
        }
        val now = SystemClock.uptimeMillis()
        if (now - lastFakeMirrorAttachUptimeMs < FAKE_MIRROR_ATTACH_THROTTLE_MS) {
            return
        }
        lastFakeMirrorAttachUptimeMs = now
        runCatching {
            val relayClass = findTargetClass(classLoader, XIAOMI_MIRROR_CALL_SERVICE)
            val terminalClass = findTargetClass(classLoader, XIAOMI_MIRROR_TERMINAL)
            val relayService = relayClass.getMethod("q").invoke(null) ?: return@runCatching
            relayClass.getMethod("F", terminalClass).invoke(relayService, terminal)
            val oppositeId = findAttachedFakeMirrorTerminalId(relayClass, terminalClass, relayService)
            val attached = oppositeId == MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID
            log(
                "mirror fake pad call flow attach attempted " +
                    "attached=$attached " +
                    "oppositeId=${oppositeId.orEmpty()}"
            )
            if (attached) {
                maybeInjectFakeMirrorKeyData(classLoader, mode, relayClass, relayService)
            }
        }.onFailure { error ->
            log("failed to attach fake pad call flow: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorAudioStartGuard(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CALL_SERVICE,
                classLoader,
                "C",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        blockFakeMirrorAudioStart("onCallStart", param)
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror onCallStart guard: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CALL_SERVICE,
                classLoader,
                "X",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        blockFakeMirrorAudioStart("startAudioSource", param)
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror audio source guard: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CALL_SERVICE,
                classLoader,
                "W",
                Integer.TYPE,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        blockFakeMirrorAudioStart("startAudioSink", param)
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror audio sink guard: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorPlainAudioRelay(classLoader: ClassLoader) {
        runCatching {
            val sourceClass = findTargetClass(classLoader, XIAOMI_MIRROR_CONTROL_AUDIO_SOURCE)
            val methods = sourceClass.declaredMethods.filter { method -> method.name == "startAudioSource" }
            methods.forEach { method ->
                XposedBridge.hookMethod(
                    method,
                    object : XC_MethodHook() {
                        override fun beforeHookedMethod(param: MethodHookParam) {
                            if (!shouldForceFakeMirrorPlainAudioRelay()) {
                                return
                            }
                            lastFakeMirrorAudioSourceStartUptimeMs = SystemClock.uptimeMillis()
                            log("mirror fake pad plain audio source start")
                        }
                    }
                )
            }
            log("mirror plain audio source hooks installed count=${methods.size}")
        }.onFailure { error ->
            log("failed to hook mirror plain audio source: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CONTROL_AUDIO_SINK,
                classLoader,
                "startAudioSink",
                findTargetClass(classLoader, XIAOMI_MIRROR_META_INFO),
                String::class.java,
                Integer.TYPE,
                Integer.TYPE,
                Integer.TYPE,
                Integer.TYPE,
                Integer.TYPE,
                Integer.TYPE,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceFakeMirrorPlainAudioRelay()) {
                            return
                        }
                        lastFakeMirrorAudioSinkStartUptimeMs = SystemClock.uptimeMillis()
                        disableMirrorAudioEncryptionFlag(param.thisObject, "sink")
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror plain audio sink: ${error.javaClass.simpleName}: ${error.message}")
        }
        hookMirrorPlainAudioIntOptions(
            classLoader = classLoader,
            className = XIAOMI_MIRROR_CONTROL_AUDIO_SOURCE,
            methodName = "setAudioSourceOption",
            direction = "source"
        )
        hookMirrorPlainAudioByteOptions(
            classLoader = classLoader,
            className = XIAOMI_MIRROR_CONTROL_AUDIO_SOURCE,
            methodName = "setAudioSourceOption",
            direction = "source"
        )
        hookMirrorPlainAudioIntOptions(
            classLoader = classLoader,
            className = XIAOMI_MIRROR_CONTROL_AUDIO_SINK,
            methodName = "setAudioSinkOption",
            direction = "sink"
        )
        hookMirrorPlainAudioByteOptions(
            classLoader = classLoader,
            className = XIAOMI_MIRROR_CONTROL_AUDIO_SINK,
            methodName = "setAudioSinkOption",
            direction = "sink"
        )
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CONTROL,
                classLoader,
                "setMirrorOption",
                java.lang.Long.TYPE,
                Integer.TYPE,
                Integer.TYPE,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceFakeMirrorPlainAudioRelay()) {
                            return
                        }
                        val option = param.args.getOrNull(1) as? Int ?: return
                        val forcedValue = plainAudioOptionValue(option) ?: return
                        val direction = mirrorAudioStartStackDirection()
                            ?: recentMirrorAudioStartDirection()
                            ?: "call_relay"
                        val oldValue = param.args.getOrNull(2)
                        if (oldValue != forcedValue) {
                            param.args[2] = forcedValue
                            log(
                                "mirror fake pad plain audio $direction option " +
                                    "option=$option value=$oldValue->$forcedValue"
                            )
                        }
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror plain audio options: ${error.javaClass.simpleName}: ${error.message}")
        }
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CONTROL,
                classLoader,
                "setMirrorOptionByte",
                java.lang.Long.TYPE,
                Integer.TYPE,
                ByteArray::class.java,
                Integer.TYPE,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (!shouldForceFakeMirrorPlainAudioRelay()) {
                            return
                        }
                        val option = param.args.getOrNull(1) as? Int ?: return
                        if (!plainAudioByteOptionBlocked(option)) {
                            return
                        }
                        val direction = mirrorAudioStartStackDirection()
                            ?: recentMirrorAudioStartDirection()
                            ?: "call_relay"
                        val bytes = param.args.getOrNull(2) as? ByteArray
                        log(
                            "mirror fake pad plain audio $direction byte option blocked " +
                                "option=$option bytes=${bytes?.size ?: -1} len=${param.args.getOrNull(3)}"
                        )
                        param.setResult(false)
                    }
                }
            )
        }.onFailure { error ->
            log("failed to hook mirror plain audio byte options: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun hookMirrorPlainAudioIntOptions(
        classLoader: ClassLoader,
        className: String,
        methodName: String,
        direction: String
    ) {
        runCatching {
            val targetClass = findTargetClass(classLoader, className)
            val methods = targetClass.declaredMethods.filter { method ->
                method.name == methodName &&
                    method.parameterTypes.contentEquals(arrayOf(Integer.TYPE, Integer.TYPE))
            }
            methods.forEach { method ->
                XposedBridge.hookMethod(
                    method,
                    object : XC_MethodHook() {
                        override fun beforeHookedMethod(param: MethodHookParam) {
                            if (!shouldForceFakeMirrorPlainAudioRelay()) {
                                return
                            }
                            val option = param.args.getOrNull(0) as? Int ?: return
                            val forcedValue = plainAudioOptionValue(option) ?: return
                            val oldValue = param.args.getOrNull(1)
                            if (oldValue != forcedValue) {
                                param.args[1] = forcedValue
                                log(
                                    "mirror fake pad plain audio $direction wrapper option " +
                                        "option=$option value=$oldValue->$forcedValue"
                                )
                            }
                        }
                    }
                )
            }
            log("mirror plain audio $direction wrapper int option hooks installed count=${methods.size}")
        }.onFailure { error ->
            log(
                "failed to hook mirror plain audio $direction wrapper int options: " +
                    "${error.javaClass.simpleName}: ${error.message}"
            )
        }
    }

    private fun hookMirrorPlainAudioByteOptions(
        classLoader: ClassLoader,
        className: String,
        methodName: String,
        direction: String
    ) {
        runCatching {
            val targetClass = findTargetClass(classLoader, className)
            val methods = targetClass.declaredMethods.filter { method ->
                method.name == methodName &&
                    method.parameterTypes.contentEquals(arrayOf(Integer.TYPE, ByteArray::class.java, Integer.TYPE))
            }
            methods.forEach { method ->
                XposedBridge.hookMethod(
                    method,
                    object : XC_MethodHook() {
                        override fun beforeHookedMethod(param: MethodHookParam) {
                            if (!shouldForceFakeMirrorPlainAudioRelay()) {
                                return
                            }
                            val option = param.args.getOrNull(0) as? Int ?: return
                            if (!plainAudioByteOptionBlocked(option)) {
                                return
                            }
                            val bytes = param.args.getOrNull(1) as? ByteArray
                            log(
                                "mirror fake pad plain audio $direction wrapper byte option blocked " +
                                    "option=$option bytes=${bytes?.size ?: -1} len=${param.args.getOrNull(2)}"
                            )
                            param.setResult(null)
                        }
                    }
                )
            }
            log("mirror plain audio $direction wrapper byte option hooks installed count=${methods.size}")
        }.onFailure { error ->
            log(
                "failed to hook mirror plain audio $direction wrapper byte options: " +
                    "${error.javaClass.simpleName}: ${error.message}"
            )
        }
    }

    private fun shouldForceFakeMirrorPlainAudioRelay(): Boolean =
        currentFakeMirrorRemoteMode() == "pad" &&
            currentFakeMirrorRemoteUsingPadEnabled() &&
            currentFakeMirrorRemoteKeyEnabled() &&
            currentFakeMirrorRemotePlainRtpEnabled() &&
            (currentFakeMirrorRemoteCallRelayActive() || recentFakeMirrorPlainAudioSession())

    private fun recentFakeMirrorPlainAudioSession(): Boolean {
        val now = SystemClock.uptimeMillis()
        return recentlyUpdated(lastFakeMirrorAttachUptimeMs, now, FAKE_MIRROR_PLAIN_AUDIO_SESSION_WINDOW_MS) ||
            recentlyUpdated(lastFakeMirrorKeyUptimeMs, now, FAKE_MIRROR_PLAIN_AUDIO_SESSION_WINDOW_MS) ||
            recentlyUpdated(lastFakeMirrorAudioParamsUptimeMs, now, FAKE_MIRROR_PLAIN_AUDIO_SESSION_WINDOW_MS) ||
            recentlyUpdated(lastFakeMirrorAudioStartProbeUptimeMs, now, FAKE_MIRROR_PLAIN_AUDIO_SESSION_WINDOW_MS) ||
            recentlyUpdated(lastFakeMirrorAudioSourceStartUptimeMs, now, FAKE_MIRROR_PLAIN_AUDIO_SESSION_WINDOW_MS) ||
            recentlyUpdated(lastFakeMirrorAudioSinkStartUptimeMs, now, FAKE_MIRROR_PLAIN_AUDIO_SESSION_WINDOW_MS)
    }

    private fun recentlyUpdated(timestampUptimeMs: Long, nowUptimeMs: Long, windowMs: Long): Boolean =
        timestampUptimeMs > 0L && nowUptimeMs - timestampUptimeMs in 0..windowMs

    private fun disableMirrorAudioEncryptionFlag(target: Any?, direction: String) {
        if (target == null) {
            return
        }
        runCatching {
            val field = target.javaClass.getDeclaredField(MIRROR_AUDIO_FIELD_ENCRYPT_ENABLE)
            field.isAccessible = true
            field.setBoolean(target, false)
            log("mirror fake pad plain audio $direction enabled")
        }.onFailure { error ->
            log(
                "failed to disable fake pad audio $direction encryption flag: " +
                    "${error.javaClass.simpleName}: ${error.message}"
            )
        }
    }

    private fun plainAudioOptionValue(option: Int): Int? =
        when (option) {
            MIRROR_OPTION_ENCRYPT_TRANS_BY_MIPLAY,
            MIRROR_OPTION_ENCRYPT_LEVEL,
            MIRROR_OPTION_ENCRYPT_TRANS_LEVEL,
            MIRROR_OPTION_ENCRYPT_TYPE,
            MIRROR_OPTION_ENCRYPT_DATA_LEN,
            MIRROR_OPTION_ENCRYPT_DATA_FORMAT,
            MIRROR_OPTION_DATA_INTEGRITY_ENABLE,
            MIRROR_OPTION_DATA_INTEGRITY_LEVEL,
            MIRROR_OPTION_ENCRYPT_ENABLE,
            MIRROR_OPTION_ENCRYPT_AUTH_TYPE -> 0
            else -> null
        }

    private fun plainAudioByteOptionBlocked(option: Int): Boolean =
        option == MIRROR_OPTION_ENCRYPT_AES_KEY ||
            option == MIRROR_OPTION_ENCRYPT_AES_IV ||
            option == MIRROR_OPTION_ENCRYPT_AUTH_KEY

    private fun mirrorAudioStartStackDirection(): String? {
        val stack = Thread.currentThread().stackTrace
        if (stack.any { frame ->
                frame.className == XIAOMI_MIRROR_CONTROL_AUDIO_SOURCE &&
                    frame.methodName == "startAudioSource"
            }
        ) {
            return "source"
        }
        if (stack.any { frame ->
                frame.className == XIAOMI_MIRROR_CONTROL_AUDIO_SINK &&
                    frame.methodName == "startAudioSink"
            }
        ) {
            return "sink"
        }
        return null
    }

    private fun recentMirrorAudioStartDirection(): String? {
        val now = SystemClock.uptimeMillis()
        val sourceAge = now - lastFakeMirrorAudioSourceStartUptimeMs
        val sinkAge = now - lastFakeMirrorAudioSinkStartUptimeMs
        val sourceRecent = sourceAge in 0..MIRROR_AUDIO_START_OPTION_WINDOW_MS
        val sinkRecent = sinkAge in 0..MIRROR_AUDIO_START_OPTION_WINDOW_MS
        return when {
            sourceRecent && sinkRecent -> if (sourceAge <= sinkAge) "source_window" else "sink_window"
            sourceRecent -> "source_window"
            sinkRecent -> "sink_window"
            else -> null
        }
    }

    private fun blockFakeMirrorAudioStart(label: String, param: XC_MethodHook.MethodHookParam) {
        if (shouldBlockFakeMirrorAudioStart()) {
            maybeLogFakeMirrorAudioParams(label, param.thisObject)
            maybeProbeFakeMirrorAudioStart(label, param.thisObject)
            param.setResult(null)
            log("blocked mirror fake pad audio path label=$label")
        }
    }

    private fun shouldBlockFakeMirrorAudioStart(): Boolean =
        shouldForceMirrorCallRelay() &&
            currentFakeMirrorRemoteKeyEnabled() &&
            fakeMirrorAudioStartProbeDepth == 0 &&
            !currentFakeMirrorRemoteAudioAllowed()

    private fun maybeProbeFakeMirrorAudioStart(label: String, relayService: Any?) {
        if (relayService == null || label != "onCallStart" && label != "callState") {
            return
        }
        val startMode = currentFakeMirrorRemoteAudioStartMode() ?: return
        val now = SystemClock.uptimeMillis()
        if (now - lastFakeMirrorAudioStartProbeUptimeMs < FAKE_MIRROR_AUDIO_START_PROBE_THROTTLE_MS) {
            return
        }
        lastFakeMirrorAudioStartProbeUptimeMs = now
        val relayClass = relayService.javaClass
        log(
            "mirror fake pad audio start probe invoking " +
                "label=$label " +
                "mode=$startMode " +
                "sinkArg=${currentFakeMirrorRemoteAudioSinkArg()?.toString() ?: "<unset>"}"
        )
        fakeMirrorAudioStartProbeDepth += 1
        try {
            if (startMode == "source" || startMode == "both") {
                invokeMirrorAudioStartMethod(relayClass, relayService, "X", null, "startAudioSource")
            }
            if (startMode == "sink" || startMode == "both") {
                val sinkArg = currentFakeMirrorRemoteAudioSinkArg()
                if (sinkArg == null) {
                    log("mirror fake pad audio start probe skipped startAudioSink missing sinkArg")
                } else {
                    invokeMirrorAudioStartMethod(relayClass, relayService, "W", sinkArg, "startAudioSink")
                }
            }
        } finally {
            fakeMirrorAudioStartProbeDepth -= 1
        }
    }

    private fun invokeMirrorAudioStartMethod(
        relayClass: Class<*>,
        relayService: Any,
        methodName: String,
        intArg: Int?,
        label: String
    ) {
        runCatching {
            if (intArg == null) {
                relayClass.getMethod(methodName).invoke(relayService)
            } else {
                relayClass.getMethod(methodName, Integer.TYPE).invoke(relayService, intArg)
            }
            log("mirror fake pad audio start probe invoked label=$label")
        }.onFailure { error ->
            val cause = error.cause ?: error
            log("mirror fake pad audio start probe failed label=$label error=${cause.javaClass.simpleName}: ${cause.message}")
        }
    }

    private fun maybeLogFakeMirrorAudioParams(label: String, relayService: Any?) {
        if (!currentFakeMirrorRemoteAudioParamsEnabled() || relayService == null) {
            return
        }
        val now = SystemClock.uptimeMillis()
        if (now - lastFakeMirrorAudioParamsUptimeMs < FAKE_MIRROR_AUDIO_PARAMS_THROTTLE_MS) {
            return
        }
        lastFakeMirrorAudioParamsUptimeMs = now
        runCatching {
            val relayClass = relayService.javaClass
            val oppositeId = runCatching {
                val classLoader = relayClass.classLoader ?: return@runCatching null
                val terminalClass = findTargetClass(classLoader, XIAOMI_MIRROR_TERMINAL)
                findAttachedFakeMirrorTerminalId(relayClass, terminalClass, relayService)
            }.getOrNull().orEmpty()
            log(
                "mirror fake pad audio params " +
                    "label=$label " +
                    "oppositeId=$oppositeId " +
                    "keyBytes=${findMirrorSharedKeySize(relayClass, relayService)} " +
                    "strings=${summarizeMirrorStringFields(relayClass, relayService)} " +
                    "ints=${summarizeMirrorIntFields(relayClass, relayService)} " +
                    "byteArrays=${summarizeMirrorByteArrayFields(relayClass, relayService)}"
            )
        }.onFailure { error ->
            log("failed to log fake pad audio params: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun maybeInjectFakeMirrorKeyData(
        classLoader: ClassLoader,
        mode: String,
        relayClass: Class<*>,
        relayService: Any
    ) {
        if (mode != "pad" || !shouldInjectFakeMirrorKeyData()) {
            return
        }
        val now = SystemClock.uptimeMillis()
        if (now - lastFakeMirrorKeyUptimeMs < FAKE_MIRROR_KEY_THROTTLE_MS) {
            maybeProbeFakeMirrorCallStateWithCurrentKey(relayClass, relayService, "key_throttled")
            return
        }
        lastFakeMirrorKeyUptimeMs = now
        runCatching {
            val keyDataValue = createFakePeerKeyDataValue(classLoader)
            relayClass.getMethod("D", String::class.java).invoke(relayService, keyDataValue.strValue)
            maybeApplyFakeMirrorAudioEndpointOverrides(relayClass, relayService)
            log(
                "mirror fake pad key data queued " +
                    "peerIp=${keyDataValue.peerIp} " +
                    "peerPort=${keyDataValue.peerPort} " +
                    "peerPublicKeyBytes=${keyDataValue.publicKeySize}"
            )
            Handler(Looper.getMainLooper()).postDelayed(
                {
                    maybeProbeFakeMirrorCallStateWithCurrentKey(relayClass, relayService, "key_injected")
                },
                FAKE_MIRROR_KEY_STATUS_DELAY_MS
            )
        }.onFailure { error ->
            log("failed to inject fake pad key data: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun maybeProbeFakeMirrorCallStateWithCurrentKey(
        relayClass: Class<*>,
        relayService: Any,
        reason: String
    ) {
        runCatching {
            val sharedKeySize = findMirrorSharedKeySize(relayClass, relayService)
            val keyReady = sharedKeySize >= MIRROR_SHARED_KEY_MIN_BYTES
            log(
                "mirror fake pad key data status " +
                    "reason=$reason " +
                    "keyReady=$keyReady " +
                    "sharedKeyBytes=$sharedKeySize"
            )
            maybeProbeFakeMirrorCallState(relayClass, relayService, keyReady)
        }.onFailure { error ->
            log("failed to probe fake pad call state with current key: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private data class FakePeerKeyDataValue(
        val strValue: String,
        val publicKeySize: Int,
        val peerIp: String,
        val peerPort: Int
    )

    private fun createFakePeerKeyDataValue(classLoader: ClassLoader): FakePeerKeyDataValue {
        val ecdhClass = findFirstTargetClass(
            classLoader,
            XIAOMI_MIRROR_ECDH_HELPER,
            XIAOMI_MIRROR_ECDH_HELPER_JADX_NAME
        )
        val keyDataClass = findTargetClass(classLoader, XIAOMI_MIRROR_KEY_DATA)
        val codecClass = findTargetClass(classLoader, XIAOMI_JSON_CODEC)
        val ecdh = ecdhClass.getDeclaredConstructor().newInstance()
        ecdhClass.getMethod("d").invoke(ecdh)
        val publicKey = ecdhClass.getMethod("b").invoke(ecdh) as ByteArray
        val peerIp = currentFakeMirrorRemotePeerIp() ?: DEFAULT_FAKE_MIRROR_PEER_IP
        val peerPort = currentFakeMirrorRemotePeerPort() ?: DEFAULT_FAKE_MIRROR_PEER_PORT
        val keyData = keyDataClass.getDeclaredConstructor().newInstance()
        keyDataClass.getField("keyBytes").set(keyData, publicKey)
        keyDataClass.getField("p2pIp").set(keyData, peerIp)
        keyDataClass.getField("port").setInt(keyData, peerPort)
        val codec = codecClass.getDeclaredConstructor().newInstance()
        val strValue = codecClass.getMethod("u", Any::class.java).invoke(codec, keyData) as String
        return FakePeerKeyDataValue(
            strValue = strValue,
            publicKeySize = publicKey.size,
            peerIp = peerIp,
            peerPort = peerPort
        )
    }

    private fun maybeApplyFakeMirrorAudioEndpointOverrides(relayClass: Class<*>, relayService: Any) {
        val updates = mutableListOf<String>()
        currentFakeMirrorRemoteLocalIp()?.let { localIp ->
            if (setMirrorStringField(relayClass, relayService, MIRROR_RELAY_FIELD_LOCAL_IP, localIp)) {
                updates += "localIp=$localIp"
            }
        }
        currentFakeMirrorRemoteLocalPort()?.let { localPort ->
            if (setMirrorIntField(relayClass, relayService, MIRROR_RELAY_FIELD_LOCAL_PORT, localPort)) {
                updates += "localPort=$localPort"
            }
        }
        currentFakeMirrorRemotePeerIp()?.let { peerIp ->
            if (setMirrorStringField(relayClass, relayService, MIRROR_RELAY_FIELD_PEER_IP, peerIp)) {
                updates += "peerIp=$peerIp"
            }
        }
        currentFakeMirrorRemotePeerPort()?.let { peerPort ->
            if (setMirrorIntField(relayClass, relayService, MIRROR_RELAY_FIELD_PEER_PORT, peerPort)) {
                updates += "peerPort=$peerPort"
            }
        }
        if (updates.isNotEmpty()) {
            log("mirror fake pad audio endpoint override ${updates.joinToString(" ")}")
        }
    }

    private fun setMirrorStringField(
        relayClass: Class<*>,
        relayService: Any,
        fieldName: String,
        value: String
    ): Boolean =
        setMirrorField(relayClass, relayService, fieldName, String::class.java) { field ->
            field.set(relayService, value)
        }

    private fun setMirrorIntField(
        relayClass: Class<*>,
        relayService: Any,
        fieldName: String,
        value: Int
    ): Boolean =
        setMirrorField(relayClass, relayService, fieldName, Integer.TYPE) { field ->
            field.setInt(relayService, value)
        }

    private fun setMirrorBooleanField(
        relayClass: Class<*>,
        relayService: Any,
        fieldName: String,
        value: Boolean
    ): Boolean =
        setMirrorField(relayClass, relayService, fieldName, java.lang.Boolean.TYPE) { field ->
            field.setBoolean(relayService, value)
        }

    private fun getMirrorBooleanField(
        relayClass: Class<*>,
        relayService: Any,
        fieldName: String
    ): Boolean? =
        runCatching {
            val field = relayClass.declaredFields.firstOrNull { candidate ->
                !Modifier.isStatic(candidate.modifiers) &&
                    candidate.name == fieldName &&
                    candidate.type == java.lang.Boolean.TYPE
            } ?: return@runCatching null
            field.isAccessible = true
            field.getBoolean(relayService)
        }.getOrNull()

    private fun getMirrorFieldValue(
        relayClass: Class<*>,
        relayService: Any,
        fieldName: String
    ): Any? =
        runCatching {
            val field = relayClass.declaredFields.firstOrNull { candidate ->
                !Modifier.isStatic(candidate.modifiers) && candidate.name == fieldName
            } ?: return@runCatching null
            field.isAccessible = true
            field.get(relayService)
        }.getOrNull()

    private fun setMirrorField(
        relayClass: Class<*>,
        relayService: Any,
        fieldName: String,
        type: Class<*>,
        setter: (java.lang.reflect.Field) -> Unit
    ): Boolean {
        val field = relayClass.declaredFields.firstOrNull { field ->
            !Modifier.isStatic(field.modifiers) && field.name == fieldName && field.type == type
        } ?: return false
        return runCatching {
            field.isAccessible = true
            setter(field)
        }.isSuccess
    }

    private fun findMirrorSharedKeySize(relayClass: Class<*>, relayService: Any): Int {
        for (field in relayClass.declaredFields) {
            if (field.type != ByteArray::class.java) {
                continue
            }
            val value = runCatching {
                field.isAccessible = true
                field.get(relayService) as? ByteArray
            }.getOrNull() ?: continue
            if (value.size >= MIRROR_SHARED_KEY_MIN_BYTES) {
                return value.size
            }
        }
        return 0
    }

    private fun summarizeMirrorStringFields(relayClass: Class<*>, relayService: Any): String =
        summarizeMirrorFields(relayClass, relayService, String::class.java) { field, index ->
            val value = runCatching {
                field.isAccessible = true
                field.get(relayService) as? String
            }.getOrNull()
            "${fieldSummaryName(index, field.name)}:${sanitizeMirrorFieldValue(value)}"
        }

    private fun summarizeMirrorIntFields(relayClass: Class<*>, relayService: Any): String =
        summarizeMirrorFields(relayClass, relayService, Integer.TYPE) { field, index ->
            val value = runCatching {
                field.isAccessible = true
                field.getInt(relayService).toString()
            }.getOrDefault("?")
            "${fieldSummaryName(index, field.name)}:$value"
        }

    private fun summarizeMirrorByteArrayFields(relayClass: Class<*>, relayService: Any): String =
        summarizeMirrorFields(relayClass, relayService, ByteArray::class.java) { field, index ->
            val size = runCatching {
                field.isAccessible = true
                (field.get(relayService) as? ByteArray)?.size ?: 0
            }.getOrDefault(0)
            "${fieldSummaryName(index, field.name)}:${size}b"
        }

    private fun summarizeMirrorFields(
        relayClass: Class<*>,
        relayService: Any,
        type: Class<*>,
        formatter: (java.lang.reflect.Field, Int) -> String
    ): String {
        val values = relayClass.declaredFields.mapIndexedNotNull { index, field ->
            if (Modifier.isStatic(field.modifiers) || field.type != type) {
                null
            } else {
                formatter(field, index)
            }
        }
        return values.take(MAX_MIRROR_AUDIO_PARAM_FIELDS).joinToString(",").ifEmpty { "<none>" }
    }

    private fun sanitizeMirrorFieldValue(value: String?): String {
        if (value.isNullOrBlank()) {
            return "<blank>"
        }
        return value
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .take(MAX_MIRROR_FIELD_VALUE_CHARS)
    }

    private fun fieldSummaryName(index: Int, name: String): String =
        "$index:$name"

    private fun maybeProbeFakeMirrorCallState(
        relayClass: Class<*>,
        relayService: Any,
        keyReady: Boolean
    ) {
        val callState = currentFakeMirrorRemoteCallState() ?: return
        if (!keyReady) {
            log("mirror fake pad call state probe skipped state=$callState keyReady=false")
            return
        }
        runCatching {
            val usingPad = relayClass.getMethod("A").invoke(relayService) as? Boolean ?: false
            log(
                "mirror fake pad call state probe invoking " +
                    "state=$callState " +
                    "usingPad=$usingPad " +
                    "audioAllowed=${currentFakeMirrorRemoteAudioAllowed()}"
            )
            relayClass.getMethod("s", Integer.TYPE).invoke(relayService, callState)
            if (callState == 0) {
                forceStopFakeMirrorAudioRelay(relayClass, relayService)
            } else if (currentFakeMirrorRemoteAudioStartMode() != null) {
                maybeLogFakeMirrorAudioParams("callState", relayService)
                forceStopFakeMirrorAudioRelay(relayClass, relayService)
                maybeProbeFakeMirrorAudioStart("callState", relayService)
            }
        }.onFailure { error ->
            log("failed to probe fake pad call state: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun forceStopFakeMirrorAudioRelay(relayClass: Class<*>, relayService: Any) {
        runCatching {
            val sourceWasOpen = getMirrorBooleanField(relayClass, relayService, MIRROR_RELAY_FIELD_AUDIO_SOURCE_OPEN)
            val sinkWasOpen = getMirrorBooleanField(relayClass, relayService, MIRROR_RELAY_FIELD_AUDIO_SINK_OPEN)
            relayClass.getMethod("Z").invoke(relayService)
            val audioManager = getMirrorFieldValue(relayClass, relayService, MIRROR_RELAY_FIELD_AUDIO_MANAGER)
            runCatching { audioManager?.javaClass?.getMethod("l")?.invoke(audioManager) }
            runCatching { audioManager?.javaClass?.getMethod("k")?.invoke(audioManager) }
            setMirrorBooleanField(relayClass, relayService, MIRROR_RELAY_FIELD_AUDIO_SOURCE_OPEN, false)
            setMirrorBooleanField(relayClass, relayService, MIRROR_RELAY_FIELD_AUDIO_SINK_OPEN, false)
            val sourceOpen = getMirrorBooleanField(relayClass, relayService, MIRROR_RELAY_FIELD_AUDIO_SOURCE_OPEN)
            val sinkOpen = getMirrorBooleanField(relayClass, relayService, MIRROR_RELAY_FIELD_AUDIO_SINK_OPEN)
            log(
                "mirror fake pad audio forced idle " +
                    "sourceWasOpen=${sourceWasOpen?.toString() ?: "?"} " +
                    "sinkWasOpen=${sinkWasOpen?.toString() ?: "?"} " +
                    "sourceOpen=${sourceOpen?.toString() ?: "?"} " +
                    "sinkOpen=${sinkOpen?.toString() ?: "?"}"
            )
        }.onFailure { error ->
            log("failed to force fake pad audio idle: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun findAttachedFakeMirrorTerminalId(
        relayClass: Class<*>,
        terminalClass: Class<*>,
        relayService: Any
    ): String? {
        for (field in relayClass.declaredFields) {
            if (!terminalClass.isAssignableFrom(field.type)) {
                continue
            }
            val terminal = runCatching {
                field.isAccessible = true
                field.get(relayService)
            }.getOrNull() ?: continue
            val id = runCatching { callTargetMethod(terminal, "h") as? String }.getOrNull()
            if (id == MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID) {
                return id
            }
        }
        return null
    }

    private fun createFakeMirrorRemoteInfo(classLoader: ClassLoader, mode: String): Parcelable? =
        runCatching {
            val remoteClass = findTargetClass(classLoader, XIAOMI_MIRROR_REMOTE_DEVICE_INFO)
            val remote = remoteClass.getDeclaredConstructor().newInstance() as Parcelable
            val bundle = callTargetMethod(remote, "getBundle") as Bundle
            bundle.putString("id", MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
            bundle.putString("device_id", MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
            bundle.putString("display_name", MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_NAME)
            bundle.putString("address", FAKE_MIRROR_LINK_ADDRESS)
            bundle.putString("platform", MiLinkPrivilegeHookPolicy.fakeMirrorRemotePlatform(mode))
            bundle.putString("manufacturer", "xiaomi")
            bundle.putLong("app_version", 170130L)
            bundle.putInt("account_status", 1)
            bundle.putInt("connect_type", 2)
            bundle.putBoolean("is_lyra", false)
            bundle.putBoolean("is_show_mirror", true)
            bundle.putBoolean("is_support_send_app", true)
            bundle.putBoolean("is_support_subscreen", true)
            bundle.putSerializable("capabilities", fakeMirrorCapabilities(mode))
            bundle.putString("product_type", if (mode == "car") "AndroidPadCar" else "AndroidPad")
            bundle.putInt("is_media_relay", 1)
            bundle.putInt("is_mirror_enabled", 1)
            bundle.putInt("is_subscreen_enabled", 1)
            bundle.putInt("is_support_enable_mirror", 1)
            remote
        }.onFailure { error ->
            log("failed to create fake mirror remote: ${error.javaClass.simpleName}: ${error.message}")
        }.getOrNull()

    private fun prepareFakeMirrorTerminal(classLoader: ClassLoader, mode: String): Any? =
        runCatching {
            val terminalClass = findTargetClass(classLoader, XIAOMI_MIRROR_TERMINAL)
            val terminal = terminalClass.getMethod("Q", String::class.java)
                .invoke(null, MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
                ?: return@runCatching null
            callStringTargetMethod(terminal, "H", MiLinkPrivilegeHookPolicy.fakeMirrorRemotePlatform(mode))
            callStringTargetMethod(terminal, "D", "xiaomi")
            callStringTargetMethod(terminal, "x", MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_NAME)
            callStringTargetMethod(terminal, "F", MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
            callStringTargetMethod(terminal, "K", FAKE_MIRROR_LINK_ADDRESS)
            callInetAddressTargetMethod(
                terminal,
                "u",
                currentFakeMirrorRemotePeerIp() ?: DEFAULT_FAKE_MIRROR_PEER_IP
            )
            callStringTargetMethod(terminal, "I", if (mode == "car") "AndroidPadCar" else "AndroidPad")
            callIntTargetMethod(terminal, "v", 170130)
            callIntTargetMethod(terminal, "t", 1)
            callIntTargetMethod(terminal, "a", 2)
            terminal.javaClass.getMethod("B0", Map::class.java)
                .invoke(terminal, fakeMirrorCapabilities(mode))
            callBooleanTargetMethod(terminal, "F0", true)
            callIntTargetMethod(terminal, "H0", 1)
            callIntTargetMethod(terminal, "N0", 1)
            callIntTargetMethod(terminal, "L0", 1)
            callIntTargetMethod(terminal, "O0", 1)
            terminal
        }.onFailure { error ->
            log("failed to prepare fake mirror terminal: ${error.javaClass.simpleName}: ${error.message}")
        }.getOrNull()

    private fun prepareFakeMirrorSourceTerminal(classLoader: ClassLoader): Any? =
        runCatching {
            val terminalClass = findTargetClass(classLoader, XIAOMI_MIRROR_TERMINAL)
            val terminal = terminalClass.getMethod("Q", String::class.java)
                .invoke(null, MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
                ?: return@runCatching null
            callStringTargetMethod(terminal, "H", "Mac")
            callStringTargetMethod(terminal, "D", "xiaomi")
            callStringTargetMethod(terminal, "x", MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_NAME)
            callStringTargetMethod(terminal, "F", MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
            callStringTargetMethod(terminal, "K", FAKE_MIRROR_LINK_ADDRESS)
            callInetAddressTargetMethod(
                terminal,
                "u",
                currentFakeMirrorRemotePeerIp() ?: DEFAULT_FAKE_MIRROR_PEER_IP
            )
            callStringTargetMethod(terminal, "I", "Mac")
            callIntTargetMethod(terminal, "v", 170130)
            callIntTargetMethod(terminal, "t", 1)
            callIntTargetMethod(terminal, "a", 2)
            terminal.javaClass.getMethod("B0", Map::class.java)
                .invoke(terminal, fakeMirrorCapabilities("pad"))
            callBooleanTargetMethod(terminal, "F0", true)
            callIntTargetMethod(terminal, "H0", 1)
            callIntTargetMethod(terminal, "N0", 1)
            callIntTargetMethod(terminal, "L0", 1)
            callIntTargetMethod(terminal, "O0", 1)
            log(
                "mirror fake source terminal prepared " +
                    "terminal=${identitySummary(terminal)} " +
                    "id=${mirrorTerminalId(terminal).orEmpty()} " +
                    "platform=${mirrorTerminalPlatform(terminal)} " +
                    "ip=${mirrorTerminalIp(terminal)}"
            )
            terminal
        }.onFailure { error ->
            log("failed to prepare fake mirror source terminal: ${error.javaClass.simpleName}: ${error.message}")
        }.getOrNull()

    private fun fakeMirrorCapabilities(mode: String): HashMap<String, String> =
        hashMapOf(
            MiLinkPrivilegeHookPolicy.XIAOMI_MIRROR_PACKAGE to when (mode) {
                "car" -> "mirror_switch;subscreen_switch;media_switch;multi_audio_channel"
                else -> "mirror_switch;subscreen_switch;media_switch"
            }
        )

    private fun readRemoteDeviceId(remote: Parcelable?): String? =
        runCatching {
            if (remote == null) {
                return@runCatching null
            }
            val bundle = callTargetMethod(remote, "getBundle") as? Bundle
            bundle?.getString("id")
        }.getOrNull()

    private fun findTargetClass(classLoader: ClassLoader, className: String): Class<*> =
        Class.forName(className, false, classLoader)

    private fun findFirstTargetClass(classLoader: ClassLoader, vararg classNames: String): Class<*> {
        var lastError: Throwable? = null
        for (className in classNames) {
            val result = runCatching { findTargetClass(classLoader, className) }
            if (result.isSuccess) {
                return result.getOrThrow()
            }
            lastError = result.exceptionOrNull()
        }
        throw ClassNotFoundException(classNames.joinToString(","), lastError)
    }

    private fun callTargetMethod(target: Any, methodName: String): Any? =
        target.javaClass.getMethod(methodName).invoke(target)

    private fun callStringTargetMethod(target: Any, methodName: String, value: String) {
        target.javaClass.getMethod(methodName, String::class.java).invoke(target, value)
    }

    private fun callIntTargetMethod(target: Any, methodName: String, value: Int) {
        target.javaClass.getMethod(methodName, Integer.TYPE).invoke(target, value)
    }

    private fun callBooleanTargetMethod(target: Any, methodName: String, value: Boolean) {
        target.javaClass.getMethod(methodName, java.lang.Boolean.TYPE).invoke(target, value)
    }

    private fun callInetAddressTargetMethod(target: Any, methodName: String, value: String) {
        target.javaClass.getMethod(methodName, InetAddress::class.java)
            .invoke(target, InetAddress.getByName(value))
    }

    private fun mirrorSinkStateSummary(target: Any?, deviceIdHint: String?): String {
        val terminal = readMirrorSinkTerminal(target)
        val advReference = readMirrorSinkAdvReference(target)
        val deviceId = mirrorSinkDeviceId(target, deviceIdHint).orEmpty()
        val isLyra = readReflectiveFieldAny(target, "n", "f10723n") as? Boolean
        val port = runCatching {
            target?.javaClass?.getMethod("getPort")?.invoke(target) as? Int
        }.getOrNull() ?: readMirrorSinkPort(target)
        val surface = readMirrorSinkSurface(target) as? Surface
        return "deviceId=$deviceId " +
            "lyra=${isLyra?.toString() ?: "?"} " +
            "terminal=${identitySummary(terminal)} " +
            "terminalId=${mirrorTerminalId(terminal).orEmpty()} " +
            "terminalIp=${mirrorTerminalIp(terminal)} " +
            "adv=${identitySummary(advReference)} " +
            "advState=${mirrorAdvState(advReference)} " +
            "port=${port ?: -1} " +
            "surface=${surface != null} " +
            "surfaceValid=${surface?.isValid == true}"
    }

    private fun mirrorSinkDeviceId(target: Any?, deviceIdHint: String? = null): String? =
        deviceIdHint?.takeIf { it.isNotBlank() }
            ?: runCatching {
                target?.javaClass?.getMethod("getDeviceId")?.invoke(target) as? String
            }.getOrNull()
            ?: readReflectiveStringFieldAny(target, "k", "f10720k")

    private fun readMirrorSinkTerminal(target: Any?): Any? =
        readReflectiveFieldAny(target, "o", "f10724o")

    private fun readMirrorSinkAdvReference(target: Any?): Any? =
        readReflectiveFieldAny(target, "s", "f10733s")

    private fun readMirrorSinkPort(target: Any?): Int? =
        readReflectiveFieldAny(target, "t", "f10734t") as? Int

    private fun readMirrorSinkDisplayType(target: Any?): Int? =
        readReflectiveFieldAny(target, "l", "f10721l") as? Int

    private fun readMirrorSinkSurface(target: Any?): Any? =
        readReflectiveFieldAny(target, "y", "f10744y")

    private fun mirrorTerminalId(terminal: Any?): String? =
        runCatching {
            if (terminal == null) {
                return@runCatching null
            }
            terminal.javaClass.getMethod("h").invoke(terminal) as? String
        }.getOrNull()

    private fun mirrorTerminalIp(terminal: Any?): String =
        runCatching {
            if (terminal == null) {
                return@runCatching ""
            }
            val address = terminal.javaClass.getMethod("b").invoke(terminal) as? InetAddress
            address?.hostAddress.orEmpty()
        }.getOrDefault("")

    private fun mirrorTerminalPlatform(terminal: Any?): String =
        runCatching {
            if (terminal == null) {
                return@runCatching ""
            }
            (terminal.javaClass.getMethod("n").invoke(terminal) as? String).orEmpty()
        }.getOrDefault("")

    private fun mirrorControlSourceSummary(source: Any?): String {
        val ip = readReflectiveStringFieldAny(source, "ip")
        val port = readReflectiveFieldAny(source, "port") as? Int
        val handler = readReflectiveFieldAny(source, "mirrorHandler") as? Long
        val optionHandle = readMirrorControlSourceOptionHandle(source)
        val hevc = readReflectiveFieldAny(source, "hevc") as? Boolean
        val hasAudio = readReflectiveFieldAny(source, "has_audio") as? Boolean
        val runCapture = readReflectiveFieldAny(source, "run_capture") as? Boolean
        return "source=${identitySummary(source)} " +
            "ip=${ip.orEmpty()} " +
            "port=${port ?: -1} " +
            "handler=${handler ?: -1L} " +
            "option=$optionHandle " +
            "hevc=${hevc ?: false} " +
            "hasAudio=${hasAudio ?: false} " +
            "runCapture=${runCapture ?: false}"
    }

    private fun readMirrorControlSourceOptionHandle(source: Any?): Long =
        (readReflectiveFieldAny(source, "optionHandle") as? Number)?.toLong() ?: 0L

    private fun isMirrorSourceAuthOption(option: Int): Boolean =
        option == MIRROR_SOURCE_OPTION_ENCRYPT_AUTH_KEY ||
            option == MIRROR_SOURCE_OPTION_ENCRYPT_AUTH_TYPE ||
            option == MIRROR_OPTION_ENCRYPT_AES_KEY ||
            option == MIRROR_OPTION_ENCRYPT_AES_IV ||
            option == MIRROR_OPTION_ENCRYPT_TRANS_BY_MIPLAY

    private fun shouldLogMirrorSourceOption(handle: Long, option: Int): Boolean =
        shouldForceMirrorSourceSession() &&
            (isMirrorSourceAuthOption(option) || handle == fakeMirrorSourceOptionHandle)

    private fun summarizeMirrorOptionArgs(args: Array<Any?>): String =
        args.mapIndexed { index, value ->
            val summary = when (value) {
                is ByteArray -> summarizeByteArray(value)
                is String -> sanitizeMirrorFieldValue(value)
                else -> value?.toString() ?: "null"
            }
            "$index=$summary"
        }.joinToString(",")

    private fun summarizeByteArray(value: ByteArray?): String {
        if (value == null) {
            return "null"
        }
        var checksum = 0
        value.forEach { byte ->
            checksum = ((checksum * 31) + (byte.toInt() and 0xff)) and 0xffff
        }
        return "${value.size}b#${checksum.toString(16)}"
    }

    private fun logMirrorSourceClassDiagnostics(source: Any?) {
        if (mirrorSourceClassDiagnosticsLogged || source == null) {
            return
        }
        mirrorSourceClassDiagnosticsLogged = true
        val sourceClass = source.javaClass
        log(
            "mirror source class diagnostics " +
                "class=${sourceClass.name} " +
                "methods=${summarizeDeclaredMethods(sourceClass)} " +
                "fields=${summarizeDeclaredFields(sourceClass)}"
        )
    }

    private fun logMirrorControlClassDiagnostics(mirrorControlClass: Class<*>) {
        if (mirrorControlClassDiagnosticsLogged) {
            return
        }
        mirrorControlClassDiagnosticsLogged = true
        log(
            "mirror control class diagnostics " +
                "class=${mirrorControlClass.name} " +
                "methods=${summarizeDeclaredMethods(mirrorControlClass)}"
        )
    }

    private fun summarizeDeclaredMethods(targetClass: Class<*>): String =
        targetClass.declaredMethods
            .sortedWith(compareBy<java.lang.reflect.Method> { it.name }.thenBy { it.parameterTypes.size })
            .take(MAX_MIRROR_METHOD_DIAGNOSTIC_COUNT)
            .joinToString("|") { method ->
                val params = method.parameterTypes.joinToString(",") { type -> type.simpleName }
                "${method.name}($params):${method.returnType.simpleName}"
            }

    private fun summarizeDeclaredFields(targetClass: Class<*>): String =
        targetClass.declaredFields
            .filter { field -> !Modifier.isStatic(field.modifiers) }
            .take(MAX_MIRROR_FIELD_DIAGNOSTIC_COUNT)
            .joinToString("|") { field -> "${field.name}:${field.type.simpleName}" }

    private fun mirrorAdvState(reference: Any?): String =
        runCatching {
            if (reference == null) {
                return@runCatching "null"
            }
            reference.javaClass.getMethod("f").invoke(reference)?.toString() ?: "null"
        }.getOrDefault("?")

    private fun identitySummary(value: Any?): String =
        if (value == null) {
            "null"
        } else {
            "${value.javaClass.name}@${System.identityHashCode(value).toString(16)}"
        }

    private fun readReflectiveStringField(target: Any?, fieldName: String): String? =
        readReflectiveField(target, fieldName) as? String

    private fun readReflectiveStringFieldAny(target: Any?, vararg fieldNames: String): String? =
        readReflectiveFieldAny(target, *fieldNames) as? String

    private fun readReflectiveField(target: Any?, fieldName: String): Any? =
        runCatching {
            if (target == null) {
                return@runCatching null
            }
            val field = findReflectiveField(target, fieldName) ?: return@runCatching null
            field.isAccessible = true
            field.get(target)
        }.getOrNull()

    private fun readReflectiveFieldAny(target: Any?, vararg fieldNames: String): Any? {
        fieldNames.forEach { fieldName ->
            val value = readReflectiveField(target, fieldName)
            if (value != null) {
                return value
            }
        }
        return null
    }

    private fun writeReflectiveField(target: Any?, fieldName: String, value: Any?): Boolean =
        runCatching {
            if (target == null) {
                return@runCatching false
            }
            val field = findReflectiveField(target, fieldName) ?: return@runCatching false
            field.isAccessible = true
            field.set(target, value)
            true
        }.getOrDefault(false)

    private fun writeReflectiveFieldAny(target: Any?, value: Any?, vararg fieldNames: String): Boolean =
        fieldNames.any { fieldName ->
            writeReflectiveField(target, fieldName, value)
        }

    private fun writeReflectiveIntField(target: Any?, fieldName: String, value: Int): Boolean =
        runCatching {
            if (target == null) {
                return@runCatching false
            }
            val field = findReflectiveField(target, fieldName) ?: return@runCatching false
            field.isAccessible = true
            field.setInt(target, value)
            true
        }.getOrDefault(false)

    private fun writeReflectiveIntFieldAny(target: Any?, value: Int, vararg fieldNames: String): Boolean =
        fieldNames.any { fieldName ->
            writeReflectiveIntField(target, fieldName, value)
        }

    private fun writeReflectiveBooleanField(target: Any?, fieldName: String, value: Boolean): Boolean =
        runCatching {
            if (target == null) {
                return@runCatching false
            }
            val field = findReflectiveField(target, fieldName) ?: return@runCatching false
            field.isAccessible = true
            field.setBoolean(target, value)
            true
        }.getOrDefault(false)

    private fun writeReflectiveBooleanFieldAny(target: Any?, value: Boolean, vararg fieldNames: String): Boolean =
        fieldNames.any { fieldName ->
            writeReflectiveBooleanField(target, fieldName, value)
        }

    private fun writeReflectiveFloatField(target: Any?, fieldName: String, value: Float): Boolean =
        runCatching {
            if (target == null) {
                return@runCatching false
            }
            val field = findReflectiveField(target, fieldName) ?: return@runCatching false
            field.isAccessible = true
            field.setFloat(target, value)
            true
        }.getOrDefault(false)

    private fun writeReflectiveFloatFieldAny(target: Any?, value: Float, vararg fieldNames: String): Boolean =
        fieldNames.any { fieldName ->
            writeReflectiveFloatField(target, fieldName, value)
        }

    private fun findReflectiveField(target: Any, fieldName: String): java.lang.reflect.Field? {
        var current: Class<*>? = target.javaClass
        while (current != null) {
            val field = runCatching { current.getDeclaredField(fieldName) }.getOrNull()
            if (field != null) {
                return field
            }
            current = current.superclass
        }
        return null
    }

    private fun currentFakeMirrorRemoteMode(): String? =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteMode(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PROPERTY)
        )

    private fun currentFakeMirrorRemoteAttachEnabled(): Boolean =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAttachEnabled(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_ATTACH_PROPERTY)
        )

    private fun currentFakeMirrorRemoteKeyEnabled(): Boolean =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteKeyEnabled(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_KEY_PROPERTY)
        )

    private fun currentFakeMirrorRemoteUsingPadEnabled(): Boolean =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteUsingPadEnabled(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_USING_PAD_PROPERTY)
        )

    private fun currentFakeMirrorRemoteCallRelayActive(): Boolean =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteCallRelayActive(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_CALL_RELAY_UNTIL_PROPERTY),
            System.currentTimeMillis()
        )

    private fun currentFakeMirrorCallRelayMode(): String? =
        currentFakeMirrorRemoteMode()?.takeIf { currentFakeMirrorRemoteCallRelayActive() }

    private fun currentFakeMirrorScreenMode(): String? =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteMode(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_SCREEN_PROPERTY)
        )?.takeIf {
            MiLinkPrivilegeHookPolicy.mirrorFakeRemoteScreenActive(
                readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_SCREEN_UNTIL_PROPERTY),
                System.currentTimeMillis()
            )
        }

    private fun currentFakeMirrorProviderMode(): String? =
        currentFakeMirrorCallRelayMode() ?: currentFakeMirrorScreenMode()

    private fun currentFakeMirrorRemoteCallState(): Int? =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteCallState(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_CALL_STATE_PROPERTY)
        )

    private fun currentFakeMirrorRemoteAudioAllowed(): Boolean =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioAllowed(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_AUDIO_PROPERTY)
        )

    private fun currentFakeMirrorRemoteAudioParamsEnabled(): Boolean =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioParamsEnabled(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_AUDIO_PARAMS_PROPERTY)
        )

    private fun currentFakeMirrorRemoteAudioStartMode(): String? =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_AUDIO_START_PROPERTY)
        )

    private fun currentFakeMirrorRemoteAudioSinkArg(): Int? =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioSinkArg(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_AUDIO_SINK_ARG_PROPERTY)
        )

    private fun currentFakeMirrorRemotePlainRtpEnabled(): Boolean =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemotePlainRtpEnabled(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PLAIN_RTP_PROPERTY)
        )

    private fun currentFakeMirrorRemotePeerIp(): String? =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointHost(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PEER_IP_PROPERTY)
        )

    private fun currentFakeMirrorRemotePeerPort(): Int? =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointPort(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PEER_PORT_PROPERTY)
        )

    private fun currentFakeMirrorRemoteLocalIp(): String? =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointHost(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_LOCAL_IP_PROPERTY)
        )

    private fun currentFakeMirrorRemoteLocalPort(): Int? =
        MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointPort(
            readSystemProperty(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_LOCAL_PORT_PROPERTY)
        )

    private fun currentFakeMirrorSourceBindIp(): String =
        currentFakeMirrorRemoteLocalIp() ?: DEFAULT_FAKE_MIRROR_SOURCE_BIND_IP

    private fun shouldForceMirrorCallRelay(): Boolean =
        currentFakeMirrorRemoteMode() == "pad" &&
            currentFakeMirrorRemoteUsingPadEnabled() &&
            currentFakeMirrorRemoteCallRelayActive()

    private fun shouldAttachFakeMirrorTerminal(): Boolean =
        currentFakeMirrorRemoteAttachEnabled() || currentFakeMirrorScreenMode() == "pad"

    private fun shouldInjectFakeMirrorKeyData(): Boolean =
        currentFakeMirrorRemoteKeyEnabled() || currentFakeMirrorScreenMode() == "pad"

    private fun shouldForceMirrorPadIdentity(): Boolean =
        shouldForceMirrorCallRelay() || currentFakeMirrorScreenMode() == "pad"

    private fun shouldForceMirrorScreenTerminalPresent(): Boolean =
        currentFakeMirrorScreenMode() == "pad"

    private fun shouldForceMirrorSourceRoute(): Boolean =
        shouldForceMirrorScreenTerminalPresent() &&
            SystemClock.uptimeMillis() < fakeMirrorSourceRouteUntilUptimeMs

    private fun shouldForceMirrorSourceSession(): Boolean =
        shouldForceMirrorSourceRoute() ||
            SystemClock.uptimeMillis() < fakeMirrorSourceSessionUntilUptimeMs

    private fun shouldOfferMirrorCallRelay(): Boolean =
        currentFakeMirrorRemoteMode() == "pad" &&
            currentFakeMirrorRemoteUsingPadEnabled()

    private fun shouldOfferInCallUiRelay(): Boolean =
        shouldOfferMirrorCallRelay()

    private fun shouldForceInCallUiRelay(): Boolean =
        shouldForceMirrorCallRelay()

    private fun shouldOfferAndroidPhoneRelay(): Boolean =
        shouldOfferMirrorCallRelay()

    private fun shouldForceAndroidPhoneRelay(): Boolean =
        shouldForceMirrorCallRelay()

    private fun shouldForceTelecomRelay(): Boolean =
        shouldForceMirrorCallRelay()

    private fun fakeRelayDeviceIdList(original: List<*>?): ArrayList<String> {
        val updated = ArrayList<String>()
        original?.forEach { value ->
            if (value is String && value.isNotBlank() && value !in updated) {
                updated.add(value)
            }
        }
        if (MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID !in updated) {
            updated.add(MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
        }
        return updated
    }

    private fun fakeInCallUiCallExtras(original: Bundle?): Bundle {
        val bundle = if (original == null) Bundle() else Bundle(original)
        bundle.putBoolean(INCALLUI_EXTRA_RELAY_CALL, true)
        bundle.putString(INCALLUI_EXTRA_RELAY_DEVICE_NAME, MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_NAME)
        if (!bundle.containsKey(INCALLUI_EXTRA_CONNECT_TIME)) {
            bundle.putLong(INCALLUI_EXTRA_CONNECT_TIME, System.currentTimeMillis())
        }
        return bundle
    }

    private fun fakeInCallUiRelayExtras(original: Bundle?): Bundle {
        val bundle = if (original == null) Bundle() else Bundle(original)
        bundle.putBoolean(INCALLUI_EXTRA_CALL_RELAYED, true)
        bundle.putBoolean(INCALLUI_EXTRA_CALL_RELAY_ANSWERED, true)
        bundle.putString(INCALLUI_EXTRA_RELAY_DEVICE_ID, MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
        bundle.putString(INCALLUI_EXTRA_RELAY_DEVICE_NAME, MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_NAME)
        return bundle
    }

    private fun notifyEdgeLinkRelaySelected(source: String, owner: Any?) {
        val now = SystemClock.uptimeMillis()
        if (now - lastInCallUiRelaySelectionUptimeMs < INCALLUI_RELAY_SELECTION_THROTTLE_MS) {
            return
        }
        lastInCallUiRelaySelectionUptimeMs = now
        val context = currentApplicationContext() ?: contextFromObject(owner)
        if (context == null) {
            log("InCallUI relay selection ignored source=$source no_context")
            return
        }
        runCatching {
            val intent = Intent(MiLinkPrivilegeHookPolicy.PHONE_RELAY_SELECTED_ACTION)
                .setPackage(MiLinkPrivilegeHookPolicy.EDGE_LINK_PACKAGE)
                .setClassName(
                    MiLinkPrivilegeHookPolicy.EDGE_LINK_PACKAGE,
                    "${MiLinkPrivilegeHookPolicy.EDGE_LINK_PACKAGE}.EdgeLinkPhoneRelaySelectionReceiver"
                )
                .putExtra(MiLinkPrivilegeHookPolicy.PHONE_RELAY_SELECTED_REASON_EXTRA, source)
                .putExtra("ts", System.currentTimeMillis())
            context.sendBroadcast(intent)
            log("InCallUI relay selection broadcast source=$source")
        }.onFailure { error ->
            log("failed to broadcast InCallUI relay selection source=$source: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun isHEVCEncoderFormat(format: MediaFormat, flags: Int): Boolean {
        val encode = flags and MediaCodec.CONFIGURE_FLAG_ENCODE != 0
        val mime = readMediaFormatString(format, MediaFormat.KEY_MIME)
        return encode && mime.equals(MIRROR_HEVC_MIME, ignoreCase = true)
    }

    private fun applyMirrorHEVCRecoveryFormat(format: MediaFormat) {
        val previousInterval = readMediaFormatInt(format, MediaFormat.KEY_I_FRAME_INTERVAL)
        runCatching {
            format.setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1)
            if (previousInterval == null || previousInterval > MIRROR_HEVC_MAX_I_FRAME_INTERVAL_SECONDS) {
                format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, MIRROR_HEVC_MAX_I_FRAME_INTERVAL_SECONDS)
            }
            log(
                "mirror hevc encoder recovery format applied " +
                    "prependHeader=1 oldIFrameInterval=${previousInterval ?: "none"} " +
                    "newIFrameInterval=${readMediaFormatInt(format, MediaFormat.KEY_I_FRAME_INTERVAL) ?: "none"}"
            )
        }.onFailure { error ->
            log("failed to apply mirror hevc recovery format: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun readMediaFormatString(format: MediaFormat, key: String): String? =
        runCatching { format.getString(key) }.getOrNull()

    private fun readMediaFormatInt(format: MediaFormat, key: String): Int? =
        runCatching { format.getInteger(key) }.getOrNull()

    private fun currentProcessName(): String =
        runCatching {
            Class.forName("android.app.Application")
                .getMethod("getProcessName")
                .invoke(null) as? String
        }.getOrNull().orEmpty()

    private fun Bundle.booleanCompat(key: String): Boolean =
        when (val value = get(key)) {
            is Boolean -> value
            is String -> value.equals("true", ignoreCase = true) ||
                value == "1" ||
                value.equals("yes", ignoreCase = true) ||
                value.equals("on", ignoreCase = true)
            is Int -> value != 0
            is Long -> value != 0L
            else -> false
        }

    private fun currentApplicationContext(): Context? =
        runCatching {
            Class.forName("android.app.ActivityThread")
                .getMethod("currentApplication")
                .invoke(null) as? Context
        }.getOrNull()?.applicationContext

    private fun contextFromObject(owner: Any?): Context? {
        if (owner is Context) {
            return owner.applicationContext
        }
        return listOf("mContext", "context")
            .firstNotNullOfOrNull { fieldName ->
                runCatching {
                    val field = owner?.javaClass?.getDeclaredField(fieldName) ?: return@runCatching null
                    field.isAccessible = true
                    (field.get(owner) as? Context)?.applicationContext
                }.getOrNull()
            }
    }

    private fun forceInCallUiRelayAnswer(inCallPresenter: Any?, source: String) {
        if (inCallPresenter == null) {
            return
        }
        val now = SystemClock.uptimeMillis()
        if (now - lastInCallUiRelayAnswerUptimeMs < INCALLUI_RELAY_ANSWER_THROTTLE_MS) {
            return
        }
        lastInCallUiRelayAnswerUptimeMs = now
        runCatching {
            val relayPresenterField = inCallPresenter.javaClass.getDeclaredField("mRelayPresenter")
            relayPresenterField.isAccessible = true
            val relayPresenter = relayPresenterField.get(inCallPresenter) ?: return@runCatching
            relayPresenter.javaClass
                .getMethod("relayAnswer", java.lang.Boolean.TYPE)
                .invoke(relayPresenter, true)
            log("InCallUI force relay answer source=$source")
        }.onFailure { error ->
            val cause = error.cause ?: error
            log("failed to force InCallUI relay answer source=$source: ${cause.javaClass.simpleName}: ${cause.message}")
        }
    }

    private fun readSystemProperty(name: String): String =
        runCatching {
            Class.forName("android.os.SystemProperties")
                .getMethod("get", String::class.java, String::class.java)
                .invoke(null, name, "") as? String
        }.getOrNull().orEmpty()

    private fun log(message: String) {
        XposedBridge.log("EdgeLinkMiLinkHook: $message")
    }

    private companion object {
        private const val MILINK_BASE_CLIENT_SERVICE = "com.milink.client.BaseClientService"
        private const val ANDROID_MEDIA_CODEC = "android.media.MediaCodec"
        private const val MILINK_PRIVILEGED_PACKAGE_MANAGER = "com.milink.base.utils.p"
        private const val MI_CONNECT_PERMISSION_CHECKER = "com.xiaomi.continuity.util.PermissionChecker"
        private const val XIAOMI_MIRROR_CALL_PROVIDER = "com.xiaomi.mirror.provider.CallProvider"
        private const val XIAOMI_MIRROR_APPLICATION = "com.xiaomi.mirror.Mirror"
        private const val XIAOMI_MIRROR_CONNECTION_MANAGER = "com.xiaomi.mirror.connection.G"
        private const val XIAOMI_MIRROR_FUSION_UTILS = "o4.B"
        private const val XIAOMI_MIRROR_REMOTE_DEVICE_INFO = "com.xiaomi.mirror.RemoteDeviceInfo"
        private const val XIAOMI_MIRROR_TERMINAL = "com.xiaomi.mirror.g0"
        private const val XIAOMI_MIRROR_SINK_VIEW = "com.xiaomi.mirror.sink.SinkView"
        private const val XIAOMI_MIRROR_SINK_VIEW_SURFACE_CALLBACK = "com.xiaomi.mirror.sink.SinkView\$a"
        private const val XIAOMI_MIRROR_ADV_CONNECTION_REFERENCE = "com.xiaomi.mirror.connection.C0701g"
        private const val XIAOMI_MIRROR_ADV_CONNECTION_REFERENCE_OBFUSCATED = "com.xiaomi.mirror.connection.g"
        private const val XIAOMI_MIRROR_CAST_BUSINESS_WRAPPER = "N2.d"
        private const val XIAOMI_MIRROR_LYRA_BUSINESS = "N2.a"
        private const val XIAOMI_MIRROR_LYRA_UTILS = "x3.z"
        private const val XIAOMI_MIRROR_NATIVE_LOG_MANAGER = "o4.Q\$a"
        private const val XIAOMI_CONTINUITY_TRUSTED_DEVICE_INFO =
            "com.xiaomi.continuity.networking.TrustedDeviceInfo"
        private const val XIAOMI_MIRROR_CALL_SERVICE = "com.xiaomi.mirror.relay.G"
        private const val XIAOMI_MIRROR_ECDH_HELPER = "com.xiaomi.mirror.relay.n"
        private const val XIAOMI_MIRROR_ECDH_HELPER_JADX_NAME = "com.xiaomi.mirror.relay.C0761n"
        private const val XIAOMI_MIRROR_KEY_DATA = "com.xiaomi.mirror.relay.KeyData"
        private const val XIAOMI_MIRROR_CONTROL = "com.xiaomi.mirrorcontrol.MirrorControl"
        private const val XIAOMI_MIRROR_CONTROL_SINK = "com.xiaomi.mirrorcontrol.MirrorControlSink"
        private const val XIAOMI_MIRROR_CONTROL_SOURCE = "com.xiaomi.mirrorcontrol.MirrorControlSource"
        private const val XIAOMI_MIRROR_SHARE_PROCESSOR = "M3.o"
        private const val XIAOMI_MIRROR_DISPLAY_MANAGER = "r3.U"
        private const val XIAOMI_MIRROR_DISPLAY_HELPER = "r3.M"
        private const val XIAOMI_MIRROR_DISPLAY_CALLBACK = "r3.Y\$a"
        private const val XIAOMI_MIRROR_CONTROL_AUDIO_SOURCE = "com.xiaomi.mirrorcontrol.MirrorControlAudioSource"
        private const val XIAOMI_MIRROR_CONTROL_AUDIO_SINK = "com.xiaomi.mirrorcontrol.MirrorControlAudioSink"
        private const val XIAOMI_MIRROR_META_INFO = "com.xiaomi.miplay.report.MirrorMetaInfo"
        private const val INCALLUI_INCALL_PRESENTER = "com.android.incallui.InCallPresenter"
        private const val INCALLUI_CALL = "com.android.incallui.Call"
        private const val INCALLUI_RELAY_UTILS = "com.android.incallui.relay.RelayUtils"
        private const val INCALLUI_RELAY_PRESENTER = "com.android.incallui.relay.RelayPresenter"
        private const val TELECOM_SIMPLE_FEATURES = "com.android.server.telecom.SimpleFeatures"
        private const val TELECOM_CALL = "com.android.server.telecom.Call"
        private const val INCALLUI_EXTRA_RELAY_CALL = "telecomm.EXTRA_RELAY_CALL"
        private const val INCALLUI_EXTRA_RELAY_DEVICE_NAME = "telecomm.EXTRA_RELAY_DEVICE_NAME"
        private const val INCALLUI_EXTRA_CALL_RELAYED = "telecomm.EXTRA_CALL_RELAYED"
        private const val INCALLUI_EXTRA_CALL_RELAY_ANSWERED = "telecomm.EXTRA_RELAY_ANSWERED"
        private const val INCALLUI_EXTRA_RELAY_DEVICE_ID = "telecomm.EXTRA_RELAY_DEVICE_ID"
        private const val INCALLUI_EXTRA_CONNECT_TIME = "telecomm.EXTRA_CONNECT_TIME"
        private const val ANDROID_PHONE_RELAY_SERVICE_BINDER =
            "com.android.services.telephony.relay.RelayService\$1"
        private const val ANDROID_PHONE_RELAY_STATE_SERVICE_BINDER =
            "com.android.services.telephony.relay.RelayStateService\$1"
        private const val XIAOMI_JSON_CODEC = "C0.d"
        private const val FAKE_MIRROR_ATTACH_THROTTLE_MS = 3_000L
        private const val FAKE_MIRROR_KEY_THROTTLE_MS = 3_000L
        private const val FAKE_MIRROR_TERMINAL_READY_THROTTLE_MS = 3_000L
        private const val FAKE_MIRROR_AUDIO_PARAMS_THROTTLE_MS = 1_000L
        private const val FAKE_MIRROR_AUDIO_START_PROBE_THROTTLE_MS = 3_000L
        private const val FAKE_MIRROR_KEY_STATUS_DELAY_MS = 250L
        private const val FAKE_MIRROR_SOURCE_ROUTE_WINDOW_MS = 30_000L
        private const val FAKE_MIRROR_SOURCE_SESSION_WINDOW_MS = 120_000L
        private const val FAKE_MIRROR_PLAIN_AUDIO_SESSION_WINDOW_MS = 120_000L
        private const val MIRROR_SOURCE_OPTION_ENCRYPT_AUTH_KEY = 41
        private const val MIRROR_SOURCE_OPTION_ENCRYPT_AUTH_TYPE = 43
        private const val MIRROR_AUTHKEY_SOURCE_NONE = 0
        private const val MIRROR_AUTHKEY_SOURCE_EXTERNAL = 3
        private val SCREEN_RTSP_AUTH_KEY =
            "EdgeLinkMirrorK!".toByteArray(Charsets.UTF_8)
        private val SCREEN_RTSP_AUTH_IV =
            "EdgeLinkMirrorIV".toByteArray(Charsets.UTF_8)
        private const val INCALLUI_RELAY_ANSWER_THROTTLE_MS = 750L
        private const val INCALLUI_RELAY_SELECTION_THROTTLE_MS = 1_000L
        private const val TELECOM_RELAY_FORCE_LOG_THROTTLE_MS = 2_000L
        private const val MIRROR_AUDIO_START_OPTION_WINDOW_MS = 2_000L
        private const val MIRROR_HEVC_MIME = "video/hevc"
        private const val MIRROR_HEVC_MAX_I_FRAME_INTERVAL_SECONDS = 1
        private const val MIRROR_HEVC_SYNC_REQUEST_THROTTLE_MS = 600L
        private const val FAKE_MIRROR_LINK_ADDRESS = "edgelink-fake-pad"
        private const val FAKE_MIRROR_TRUSTED_DEVICE_TYPE = 4
        private const val FAKE_MIRROR_TRUSTED_MEDIUM_TYPES = 65_664
        private const val FAKE_MIRROR_TRUSTED_TYPES = 1
        private const val DEFAULT_FAKE_MIRROR_PEER_IP = "127.0.0.1"
        private const val DEFAULT_FAKE_MIRROR_PEER_PORT = 7102
        private const val DEFAULT_FAKE_MIRROR_SOURCE_BIND_IP = "0.0.0.0"
        private const val MIRROR_RELAY_FIELD_LOCAL_IP = "m"
        private const val MIRROR_RELAY_FIELD_PEER_IP = "n"
        private const val MIRROR_RELAY_FIELD_LOCAL_PORT = "o"
        private const val MIRROR_RELAY_FIELD_PEER_PORT = "p"
        private const val MIRROR_RELAY_FIELD_AUDIO_MANAGER = "a"
        private const val MIRROR_RELAY_FIELD_AUDIO_SOURCE_OPEN = "i"
        private const val MIRROR_RELAY_FIELD_AUDIO_SINK_OPEN = "j"
        private const val MIRROR_AUDIO_FIELD_ENCRYPT_ENABLE = "mEncryptEnable"
        private const val MIRROR_OPTION_ENCRYPT_AES_KEY = 7
        private const val MIRROR_OPTION_ENCRYPT_AES_IV = 8
        private const val MIRROR_OPTION_ENCRYPT_TRANS_BY_MIPLAY = 9
        private const val MIRROR_OPTION_ENCRYPT_LEVEL = 10
        private const val MIRROR_OPTION_ENCRYPT_TRANS_LEVEL = 11
        private const val MIRROR_OPTION_ENCRYPT_TYPE = 12
        private const val MIRROR_OPTION_ENCRYPT_DATA_LEN = 13
        private const val MIRROR_OPTION_ENCRYPT_DATA_FORMAT = 14
        private const val MIRROR_OPTION_DATA_INTEGRITY_ENABLE = 15
        private const val MIRROR_OPTION_DATA_INTEGRITY_LEVEL = 16
        private const val MIRROR_OPTION_ENCRYPT_ENABLE = 23
        private const val MIRROR_OPTION_ENCRYPT_AUTH_KEY = 41
        private const val MIRROR_OPTION_ENCRYPT_AUTH_TYPE = 43
        private const val MIRROR_SHARED_KEY_MIN_BYTES = 16
        private const val MAX_MIRROR_AUDIO_PARAM_FIELDS = 12
        private const val MAX_MIRROR_FIELD_VALUE_CHARS = 80
        private const val MAX_MIRROR_METHOD_DIAGNOSTIC_COUNT = 80
        private const val MAX_MIRROR_FIELD_DIAGNOSTIC_COUNT = 32
    }
}
