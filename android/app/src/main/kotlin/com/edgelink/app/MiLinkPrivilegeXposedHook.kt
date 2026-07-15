package com.edgelink.app

import android.content.Context
import android.content.ContentProvider
import android.os.Binder
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Parcelable
import android.os.SystemClock
import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage
import java.lang.reflect.Modifier
import java.util.ArrayList
import java.util.HashMap

internal object MiLinkPrivilegeHookPolicy {
    const val EDGE_LINK_PACKAGE = "com.edgelink.app"
    const val MILINK_PACKAGE = "com.milink.service"
    const val MILINK_MAIN_PROCESS = "com.milink.service"
    const val MILINK_RUNTIME_PROCESS = "com.milink.runtime"
    const val XIAOMI_MIRROR_PACKAGE = "com.xiaomi.mirror"
    const val XIAOMI_MIRROR_PROCESS = "com.xiaomi.mirror"
    const val INCALLUI_PACKAGE = "com.android.incallui"
    const val INCALLUI_PROCESS = "com.android.incallui"
    const val ANDROID_PHONE_PACKAGE = "com.android.phone"
    const val ANDROID_PHONE_PROCESS = "com.android.phone"
    const val MIRROR_FAKE_REMOTE_PROPERTY = "debug.edgelink.mirror_fake_remote"
    const val MIRROR_FAKE_REMOTE_ATTACH_PROPERTY = "debug.edgelink.mirror_fake_remote_attach"
    const val MIRROR_FAKE_REMOTE_KEY_PROPERTY = "debug.edgelink.mirror_fake_remote_key"
    const val MIRROR_FAKE_REMOTE_USING_PAD_PROPERTY = "debug.edgelink.mirror_fake_remote_using_pad"
    const val MIRROR_FAKE_REMOTE_CALL_RELAY_UNTIL_PROPERTY = "debug.edgelink.mirror_fake_remote_call_relay_until"
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
            shouldHookXiaomiMirror(packageName, processName) ||
            shouldHookInCallUi(packageName, processName) ||
            shouldHookAndroidPhone(packageName, processName)

    fun shouldHookRuntime(packageName: String?, processName: String?): Boolean =
        packageName == MILINK_PACKAGE && processName == MILINK_RUNTIME_PROCESS

    fun shouldHookMainService(packageName: String?, processName: String?): Boolean =
        packageName == MILINK_PACKAGE && processName == MILINK_MAIN_PROCESS

    fun shouldHookXiaomiMirror(packageName: String?, processName: String?): Boolean =
        packageName == XIAOMI_MIRROR_PACKAGE && processName == XIAOMI_MIRROR_PROCESS

    fun shouldHookInCallUi(packageName: String?, processName: String?): Boolean =
        packageName == INCALLUI_PACKAGE && processName == INCALLUI_PROCESS

    fun shouldHookAndroidPhone(packageName: String?, processName: String?): Boolean =
        packageName == ANDROID_PHONE_PACKAGE && processName == ANDROID_PHONE_PROCESS

    fun isAllowedCallerPackage(packageName: String?): Boolean =
        packageName == EDGE_LINK_PACKAGE

    fun hasAllowedCallerPackage(packages: Array<String>?): Boolean =
        packages?.any(::isAllowedCallerPackage) == true

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
    private var lastFakeMirrorAttachUptimeMs: Long = 0L
    private var lastFakeMirrorKeyUptimeMs: Long = 0L
    private var lastFakeMirrorAudioParamsUptimeMs: Long = 0L
    private var lastFakeMirrorAudioStartProbeUptimeMs: Long = 0L
    private var lastFakeMirrorAudioSourceStartUptimeMs: Long = 0L
    private var lastFakeMirrorAudioSinkStartUptimeMs: Long = 0L
    private var lastInCallUiRelayAnswerUptimeMs: Long = 0L
    private var fakeMirrorAudioStartProbeDepth: Int = 0

    override fun handleLoadPackage(lpparam: XC_LoadPackage.LoadPackageParam) {
        if (!MiLinkPrivilegeHookPolicy.shouldHook(lpparam.packageName, lpparam.processName)) {
            return
        }

        log("loading hooks in package=${lpparam.packageName} process=${lpparam.processName}")
        if (MiLinkPrivilegeHookPolicy.shouldHookRuntime(lpparam.packageName, lpparam.processName)) {
            hookRuntimeCallingPackageCheck(lpparam.classLoader)
            hookRuntimeCallingUidCheck(lpparam.classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookMainService(lpparam.packageName, lpparam.processName)) {
            hookCastClientServiceCheck(lpparam.classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookXiaomiMirror(lpparam.packageName, lpparam.processName)) {
            hookMirrorCallProviderAccessCheck(lpparam.classLoader)
            hookMirrorRemoteExperiment(lpparam.classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookInCallUi(lpparam.packageName, lpparam.processName)) {
            hookInCallUiRelayExperiment(lpparam.classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookAndroidPhone(lpparam.packageName, lpparam.processName)) {
            hookAndroidPhoneRelayServices(lpparam.classLoader)
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

    private fun hookMirrorRemoteExperiment(classLoader: ClassLoader) {
        hookMirrorRemoteProviderResults(classLoader)
        hookMirrorTerminalLookup(classLoader)
        hookMirrorDeviceTypeChecks(classLoader)
        hookMirrorUsingPadOverride(classLoader)
        hookMirrorAudioStartGuard(classLoader)
        hookMirrorPlainAudioRelay(classLoader)
    }

    private fun hookInCallUiRelayExperiment(classLoader: ClassLoader) {
        hookInCallUiCallRelayExtras(classLoader)
        hookInCallUiRelayHelpers(classLoader)
        hookInCallUiRelayDeviceList(classLoader)
        hookInCallUiRelayForeground(classLoader)
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
                        if (!shouldForceInCallUiRelay()) {
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
                        if (!shouldForceAndroidPhoneRelay()) {
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
                        val mode = currentFakeMirrorCallRelayMode() ?: return
                        val method = param.args.getOrNull(0) as? String ?: return
                        if (method == "queryRemoteDevices" || method == "queryRemoteDevice") {
                            val terminal = prepareFakeMirrorTerminal(classLoader, mode)
                            maybeAttachFakeMirrorCallFlow(classLoader, mode, terminal)
                        }
                    }

                    override fun afterHookedMethod(param: MethodHookParam) {
                        val mode = currentFakeMirrorCallRelayMode() ?: return
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
                        val mode = currentFakeMirrorCallRelayMode() ?: return
                        val deviceId = param.args.getOrNull(0) as? String
                        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
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
                        val mode = currentFakeMirrorCallRelayMode() ?: return
                        val deviceId = param.args.getOrNull(0) as? String
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
                "w",
                String::class.java,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        val mode = currentFakeMirrorCallRelayMode() ?: return
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

    private fun hookMirrorUsingPadOverride(classLoader: ClassLoader) {
        runCatching {
            XposedHelpers.findAndHookMethod(
                XIAOMI_MIRROR_CALL_SERVICE,
                classLoader,
                "A",
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (shouldForceMirrorCallRelay()) {
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

    private fun maybeAttachFakeMirrorCallFlow(classLoader: ClassLoader, mode: String, terminal: Any?) {
        if (mode != "pad" || terminal == null || !currentFakeMirrorRemoteAttachEnabled()) {
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
        shouldForceMirrorCallRelay() &&
            currentFakeMirrorRemoteKeyEnabled() &&
            currentFakeMirrorRemotePlainRtpEnabled()

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
        if (label != "onCallStart" || relayService == null) {
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
        if (mode != "pad" || !currentFakeMirrorRemoteKeyEnabled()) {
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
            callStringTargetMethod(terminal, "K", "edgelink-fake-pad")
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

    private fun shouldForceMirrorCallRelay(): Boolean =
        currentFakeMirrorRemoteMode() == "pad" &&
            currentFakeMirrorRemoteUsingPadEnabled() &&
            currentFakeMirrorRemoteCallRelayActive()

    private fun shouldForceInCallUiRelay(): Boolean =
        shouldForceMirrorCallRelay()

    private fun shouldForceAndroidPhoneRelay(): Boolean =
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
        private const val MILINK_PRIVILEGED_PACKAGE_MANAGER = "com.milink.base.utils.p"
        private const val XIAOMI_MIRROR_CALL_PROVIDER = "com.xiaomi.mirror.provider.CallProvider"
        private const val XIAOMI_MIRROR_CONNECTION_MANAGER = "com.xiaomi.mirror.connection.G"
        private const val XIAOMI_MIRROR_FUSION_UTILS = "o4.B"
        private const val XIAOMI_MIRROR_REMOTE_DEVICE_INFO = "com.xiaomi.mirror.RemoteDeviceInfo"
        private const val XIAOMI_MIRROR_TERMINAL = "com.xiaomi.mirror.g0"
        private const val XIAOMI_MIRROR_CALL_SERVICE = "com.xiaomi.mirror.relay.G"
        private const val XIAOMI_MIRROR_ECDH_HELPER = "com.xiaomi.mirror.relay.n"
        private const val XIAOMI_MIRROR_ECDH_HELPER_JADX_NAME = "com.xiaomi.mirror.relay.C0761n"
        private const val XIAOMI_MIRROR_KEY_DATA = "com.xiaomi.mirror.relay.KeyData"
        private const val XIAOMI_MIRROR_CONTROL = "com.xiaomi.mirrorcontrol.MirrorControl"
        private const val XIAOMI_MIRROR_CONTROL_AUDIO_SOURCE = "com.xiaomi.mirrorcontrol.MirrorControlAudioSource"
        private const val XIAOMI_MIRROR_CONTROL_AUDIO_SINK = "com.xiaomi.mirrorcontrol.MirrorControlAudioSink"
        private const val XIAOMI_MIRROR_META_INFO = "com.xiaomi.miplay.report.MirrorMetaInfo"
        private const val INCALLUI_INCALL_PRESENTER = "com.android.incallui.InCallPresenter"
        private const val INCALLUI_CALL = "com.android.incallui.Call"
        private const val INCALLUI_RELAY_UTILS = "com.android.incallui.relay.RelayUtils"
        private const val INCALLUI_RELAY_PRESENTER = "com.android.incallui.relay.RelayPresenter"
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
        private const val FAKE_MIRROR_AUDIO_PARAMS_THROTTLE_MS = 1_000L
        private const val FAKE_MIRROR_AUDIO_START_PROBE_THROTTLE_MS = 3_000L
        private const val FAKE_MIRROR_KEY_STATUS_DELAY_MS = 250L
        private const val INCALLUI_RELAY_ANSWER_THROTTLE_MS = 750L
        private const val MIRROR_AUDIO_START_OPTION_WINDOW_MS = 2_000L
        private const val DEFAULT_FAKE_MIRROR_PEER_IP = "127.0.0.1"
        private const val DEFAULT_FAKE_MIRROR_PEER_PORT = 7102
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
    }
}
