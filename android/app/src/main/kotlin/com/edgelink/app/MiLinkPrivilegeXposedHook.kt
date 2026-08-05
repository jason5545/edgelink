package com.edgelink.app

import android.content.Context
import android.content.ContentProvider
import android.content.Intent
import android.os.Binder
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import io.github.libxposed.api.XposedInterface
import java.lang.reflect.Executable
import java.lang.reflect.Method
import java.lang.reflect.Modifier
import java.lang.reflect.Proxy
import java.util.ArrayList
import java.util.Collections
import java.util.HashMap
import kotlin.concurrent.thread

internal object MiLinkPrivilegeHookPolicy {
    const val EDGE_LINK_PACKAGE = "com.edgelink.app"
    const val ANDROID_PACKAGE = "android"
    const val MILINK_PACKAGE = "com.milink.service"
    const val MILINK_MAIN_PROCESS = "com.milink.service"
    const val MILINK_RUNTIME_PROCESS = "com.milink.runtime"
    const val MILINK_DISTRIBUTED_HARDWARE_PROCESS = "com.milink.service:distributedHardware"
    const val XIAOMI_MIRROR_PACKAGE = "com.xiaomi.mirror"
    const val XIAOMI_MIRROR_PROCESS = "com.xiaomi.mirror"
    const val XIAOMI_MI_CONNECT_PACKAGE = "com.xiaomi.mi_connect_service"
    const val XIAOMI_MI_CONNECT_PROCESS = "com.xiaomi.mi_connect_service"
    const val XIAOMI_MISHARE_PACKAGE = "com.miui.mishare.connectivity"
    const val XIAOMI_TRUST_SERVICE_PACKAGE = "com.xiaomi.trustservice"
    const val SYSTEM_SERVER_PROCESS = "system_server"
    const val SYSTEM_PROCESS = "system"
    const val PHONE_RELAY_SELECTED_ACTION = "com.edgelink.app.PHONE_RELAY_SELECTED"
    const val PHONE_RELAY_SELECTED_REASON_EXTRA = "reason"
    const val XIAOMI_MIRROR_CAST_FRAME_ACTION = "com.edgelink.app.XIAOMI_MIRROR_CAST_FRAME"
    const val XIAOMI_MIRROR_CAST_FRAME_EXTRA = "frame"
    const val MIRROR_FAKE_REMOTE_PROPERTY = "debug.edgelink.mirror_fake_remote"
    const val MIRROR_FAKE_REMOTE_ATTACH_PROPERTY = "debug.edgelink.mirror_fake_remote_attach"
    const val MIRROR_FAKE_REMOTE_KEY_PROPERTY = "debug.edgelink.mirror_fake_remote_key"
    const val MIRROR_FAKE_REMOTE_USING_PAD_PROPERTY = "debug.edgelink.mirror_fake_remote_using_pad"
    const val MIRROR_FAKE_REMOTE_CALL_RELAY_UNTIL_PROPERTY = "debug.edgelink.mirror_fake_remote_call_relay_until"
    const val MIRROR_FAKE_REMOTE_SCREEN_PROPERTY = "debug.edgelink.mirror_fake_remote_screen"
    const val MIRROR_FAKE_REMOTE_SCREEN_UNTIL_PROPERTY = "debug.edgelink.mirror_fake_remote_screen_until"
    const val MIRROR_FAKE_REMOTE_SCREEN_AUDIO_OWNER_PROPERTY = "debug.edgelink.mirror_fake_remote_screen_audio_owner"
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
        "setMediaRelayVolume",
        "edgeLinkGlobal",
        "edgeLinkCastChannel"
    )

    fun shouldHook(packageName: String?, processName: String?): Boolean =
        shouldHookRuntime(packageName, processName) ||
            shouldHookMainService(packageName, processName) ||
            shouldHookDistributedHardware(packageName, processName) ||
            shouldHookXiaomiMirror(packageName, processName) ||
            shouldHookMiConnectService(packageName, processName) ||
            shouldHookAndroidSystem(packageName, processName) ||
            shouldHookTrustService(packageName, processName) ||
            shouldHookMiShare(packageName, processName)

    fun shouldHookTrustService(packageName: String?, processName: String?): Boolean =
        packageName == XIAOMI_TRUST_SERVICE_PACKAGE

    fun shouldHookMiShare(packageName: String?, processName: String?): Boolean =
        packageName == XIAOMI_MISHARE_PACKAGE

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

    fun isAllowedMiConnectCallerPackage(requestedPackageName: String?, callerPackages: Array<String>?): Boolean {
        if (requestedPackageName != null && !isAllowedCallerPackage(requestedPackageName)) {
            return false
        }
        return hasAllowedCallerPackage(callerPackages)
    }

    fun isAllowedMirrorPhoneProviderMethod(method: String?): Boolean =
        method in mirrorPhoneProviderMethods

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


    fun isFakeMirrorRemoteId(deviceId: String?): Boolean =
        deviceId == FAKE_MIRROR_REMOTE_ID

    private const val MAX_ENDPOINT_HOST_CHARS = 80
}

class MiLinkPrivilegeXposedHook(private val xposed: XposedInterface) {
    private data class XiaomiMirrorKeyboardInjectionResult(
        val accepted: Boolean,
        val route: String,
        val message: String
    )

    private val mirrorKeepAwakeLockGuard = Any()
    private var mirrorKeepAwakeLock: PowerManager.WakeLock? = null
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
        synchronized(mirrorKeepAwakeLockGuard) {
            mirrorKeepAwakeLock?.let { lock ->
                runCatching { if (lock.isHeld) lock.release() }
            }
            mirrorKeepAwakeLock = null
        }
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
            installXiaomiMirrorSynergyStatusGuard(classLoader, "install")
            installMirrorCastChannelTracker(classLoader)
            hookMirrorOfficialScreenConfiguration(classLoader)
            hookMirrorSourceRecoveryProvider(classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookMiConnectService(packageName, processName)) {
            hookMiConnectNetworkingPermission(classLoader)
            boostMiConnectNativeLogging(classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookAndroidSystem(packageName, processName)) {
            hookXiaomiMirrorSystemPackageGids(classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookMiShare(packageName, processName)) {
            hookMiShareLyraTrustInjection(classLoader)
        }
        if (MiLinkPrivilegeHookPolicy.shouldHookTrustService(packageName, processName)) {
            installTrustBindBridge(classLoader)
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

    private fun installTrustBindBridge(classLoader: ClassLoader) {
        runCatching {
            val instrumentationClass = findTargetClass(classLoader, "android.app.Instrumentation")
            installHook(
                resolveMethod(
                    instrumentationClass,
                    "callApplicationOnCreate",
                    android.app.Application::class.java
                )
            ) { chain ->
                chain.proceed()
                val app = chain.args.getOrNull(0) as? android.app.Application
                if (app != null) {
                    registerTrustBindReceiver(app, classLoader)
                }
                null
            }
        }.onFailure { error ->
            log("trust bind bridge hook failed: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun registerTrustBindReceiver(app: android.app.Application, classLoader: ClassLoader) {
        runCatching {
            val receiver = object : android.content.BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    val said = intent.getStringExtra("said")
                    val pub = intent.getStringExtra("pub")
                    val hash = intent.getStringExtra("hash")
                    thread(name = "edgelink-trust-bind") {
                        if (intent.getStringExtra("bindremote") != null) {
                            runTrustBindRemote(classLoader, intent.getStringExtra("bindremote")!!)
                        } else if (said == null) {
                            log("trust bind: missing said")
                        } else if (intent.getStringExtra("seq") == "1") {
                            runTrustBindSeq(classLoader, said, pub, hash)
                        } else if (intent.getStringExtra("seq") == "2") {
                            runTrustBindSeq(classLoader, said, null, null, selfTest = true)
                        } else if (pub == null) {
                            runTrustBindSeq(classLoader, said, null, null)
                        } else {
                            runTrustBind(classLoader, said, pub, hash)
                        }
                    }
                }
            }
            app.registerReceiver(
                receiver,
                android.content.IntentFilter(TRUST_BIND_ACTION),
                Context.RECEIVER_EXPORTED
            )
            log("trust bind bridge receiver registered")
        }.onFailure { error ->
            log("trust bind bridge register failed: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun runTrustBind(classLoader: ClassLoader, saidHex: String, pubHex: String, hashHex: String?) {
        try {
            val binder = Class.forName("android.os.ServiceManager")
                .getDeclaredMethod("waitForService", String::class.java)
                .invoke(null, TRUST_SHARED_AUTH_SERVICE) as? android.os.IBinder
            if (binder == null) {
                log("trust bind: shared auth service unavailable")
                return
            }
            val stub = Class.forName("vendor.xiaomi.hardware.misauth.IMiSharedAuth\$Stub", false, classLoader)
            val service = stub.getMethod("asInterface", android.os.IBinder::class.java).invoke(null, binder)
            val iface = Class.forName("vendor.xiaomi.hardware.misauth.IMiSharedAuth", false, classLoader)
            log(
                "trust bind iface methods: " + iface.methods.joinToString { method ->
                    method.name + method.parameterTypes.joinToString(",", "(", ")") { it.simpleName }
                }
            )
            val response = iface.methods
                .first { method ->
                    method.name == "loadBindPubAV2" && method.parameterTypes.contentEquals(
                        arrayOf(ByteArray::class.java, ByteArray::class.java)
                    )
                }
                .invoke(service, trustBindHex(saidHex), trustBindHex(pubHex))
            log("trust bind loadBindPubAV2 ${describeSharedAuthResponse(response)}")
            if (!hashHex.isNullOrEmpty()) {
                val status = iface.methods
                    .first { method ->
                        method.name == "getDeviceBindStatusBV2" && method.parameterTypes.contentEquals(
                            arrayOf(ByteArray::class.java, ByteArray::class.java)
                        )
                    }
                    .invoke(service, trustBindHex(saidHex), trustBindHex(hashHex))
                log("trust bind status ${describeSharedAuthResponse(status)}")
            }
        } catch (error: Throwable) {
            log("trust bind failed: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun runTrustBindRemote(classLoader: ClassLoader, deviceId: String) {
        try {
            val i0Class = Class.forName("I0.c", false, classLoader)
            val i0 = i0Class.declaredFields
                .firstOrNull { Modifier.isStatic(it.modifiers) && it.type == i0Class }
                ?.run {
                    isAccessible = true
                    get(null)
                }
            if (i0 == null) {
                log("trust bindremote: no I0.c instance")
                return
            }
            val kClass = Class.forName("com.xiaomi.trustservice.remoteauthservice.k", false, classLoader)
            val kInstance = i0Class.declaredFields
                .firstOrNull { !Modifier.isStatic(it.modifiers) && it.type == kClass }
                ?.run {
                    isAccessible = true
                    get(i0)
                }
            if (kInstance == null) {
                log("trust bindremote: no quick auth handler")
                return
            }
            val callbackIface = Class.forName(
                "com.xiaomi.trustservice.remoteauthservice.IMiRemoteAuthServiceCallback",
                false,
                classLoader
            )
            val callback = Proxy.newProxyInstance(classLoader, arrayOf(callbackIface)) { _, method, args ->
                if (method.name == "onResult") {
                    log("trust bindremote onResult: ${args?.joinToString()}")
                }
                null
            }
            val xMethod = kClass.methods.firstOrNull { method ->
                method.parameterTypes.contentEquals(
                    arrayOf(
                        String::class.java,
                        String::class.java,
                        Boolean::class.javaPrimitiveType,
                        i0Class,
                        callbackIface
                    )
                )
            }
            if (xMethod == null) {
                log(
                    "trust bindremote: no binder entry, methods=" +
                        kClass.methods.joinToString { it.name + it.parameterTypes.joinToString(",", "(", ")") { p -> p.simpleName } }
                )
                return
            }
            xMethod.invoke(kInstance, "com.edgelink.bridge", deviceId, false, i0, callback)
            log("trust bindremote invoked for $deviceId")
        } catch (error: Throwable) {
            log("trust bindremote failed: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun runTrustBindSeq(classLoader: ClassLoader, saidHex: String, pubHex: String?, hashHex: String?, selfTest: Boolean = false) {
        try {
            val binder = Class.forName("android.os.ServiceManager")
                .getDeclaredMethod("waitForService", String::class.java)
                .invoke(null, TRUST_SHARED_AUTH_SERVICE) as? android.os.IBinder
            if (binder == null) {
                log("trust bindseq: shared auth service unavailable")
                return
            }
            val stub = Class.forName("vendor.xiaomi.hardware.misauth.IMiSharedAuth\$Stub", false, classLoader)
            val service = stub.getMethod("asInterface", android.os.IBinder::class.java).invoke(null, binder)
            val iface = Class.forName("vendor.xiaomi.hardware.misauth.IMiSharedAuth", false, classLoader)
            fun invoke(name: String, vararg args: ByteArray): Any? {
                val sig = Array(args.size) { ByteArray::class.java }
                return iface.methods
                    .first { it.name == name && it.parameterTypes.contentEquals(sig) }
                    .invoke(service, *args.map { it as Any? }.toTypedArray())
            }
            val hatResp = invoke("getBindHATChallengeV2")
            log("trust bindseq hat ${describeSharedAuthResponse(hatResp)}")
            val hatPayload = sharedAuthPayload(hatResp)
            if (hatPayload == null) {
                log("trust bindseq: no hat payload")
                return
            }
            val hat69 = ByteArray(69)
            for (i in 1 until 69) {
                if (i > hatPayload.size) break
                hat69[i] = hatPayload[i - 1]
            }
            val pubResp = invoke("getBindPubV2", hat69, trustBindHex(saidHex))
            log("trust bindseq pub ${describeSharedAuthResponse(pubResp)}")
            if (selfTest) {
                val ownBlob = sharedAuthPayload(pubResp)
                if (ownBlob != null) {
                    val loadResp = invoke("loadBindPubAV2", trustBindHex(saidHex), ownBlob)
                    log("trust bindseq selfload ${describeSharedAuthResponse(loadResp)}")
                }
                return
            }
            if (!pubHex.isNullOrEmpty()) {
                val loadResp = invoke("loadBindPubAV2", trustBindHex(saidHex), trustBindHex(pubHex))
                log("trust bindseq load ${describeSharedAuthResponse(loadResp)}")
                if (!hashHex.isNullOrEmpty()) {
                    val statusResp = invoke("getDeviceBindStatusBV2", trustBindHex(saidHex), trustBindHex(hashHex))
                    log("trust bindseq status ${describeSharedAuthResponse(statusResp)}")
                }
            }
        } catch (error: Throwable) {
            log("trust bindseq failed: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun sharedAuthPayload(response: Any?): ByteArray? {
        if (response == null) return null
        return response.javaClass.getDeclaredFields()
            .firstOrNull { it.type == ByteArray::class.java }
            ?.run {
                isAccessible = true
                get(response) as? ByteArray
            }
    }

    private fun describeSharedAuthResponse(response: Any?): String {
        if (response == null) return "null"
        val fields = response.javaClass.getDeclaredFields()
        val code = fields.firstOrNull { it.type == java.lang.Integer.TYPE }?.run {
            isAccessible = true
            getInt(response)
        } ?: -1
        val payload = fields.firstOrNull { it.type == ByteArray::class.java }?.run {
            isAccessible = true
            (get(response) as? ByteArray)?.joinToString("") { "%02x".format(it) }
        }
        return "code=$code payload=$payload"
    }

    private fun trustBindHex(value: String): ByteArray =
        ByteArray(value.length / 2) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
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
            installHook(
                resolveMethod(
                    findTargetClass(classLoader, MI_CONNECT_PERMISSION_CHECKER),
                    "checkPermissions",
                    *signature
                )
            ) { chain ->
                val context = chain.args.getOrNull(0) as? Context
                if (context != null) {
                    val requestedPackage = chain.args.getOrNull(1) as? String
                    val permission = chain.args.getOrNull(2) as? String
                    val serviceId = chain.args.getOrNull(3) as? String
                    val callerUid = Binder.getCallingUid()
                    val packages = context.packageManager.getPackagesForUid(callerUid)
                    if (MiLinkPrivilegeHookPolicy.isAllowedMiConnectCallerPackage(requestedPackage, packages)) {
                        log(
                            "allowed mi_connect networking permission callerUid=$callerUid " +
                                "requestedPackage=${requestedPackage ?: "-"} " +
                                "permission=${permission ?: "-"} serviceId=${serviceId ?: "-"}"
                        )
                        return@installHook 0
                    }
                }
                chain.proceed()
            }
        }.onFailure { error ->
            log(
                "failed to hook mi_connect permission checker args=${signature.size}: " +
                    "${error.javaClass.simpleName}: ${error.message}"
            )
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
                if (extras != null) {
                    if (method == "edgeLinkCastChannel") {
                        return@installHook Bundle().apply {
                            putLong("castChannelConfirmAtMs", lastCastChannelConfirmAtMs)
                            putString("castChannelDevice", lastCastChannelConfirmDevice)
                            putBoolean("enable", true)
                            putInt("value", 0)
                        }
                    }
                    if (method == "edgeLinkGlobal") {
                        return@installHook handleMirrorGlobalProvider(classLoader, extras)
                    }
                    if (method == "edgeLinkKeepAwake") {
                        return@installHook handleMirrorKeepAwakeProvider(extras)
                    }
                }
                chain.proceed()
            }
            log("mirror edgelink provider hook installed")
        }.onFailure { error ->
            log("failed to hook mirror edgelink provider: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun handleMirrorKeepAwakeProvider(extras: Bundle): Bundle {
        val active = extras.booleanCompat("active")
        val context = currentApplicationContext()
        if (context == null) {
            log("mirror keep-awake failed active=$active error=no_context")
            return Bundle().apply {
                putBoolean("keepAwakeApplied", false)
                putString("keepAwakeError", "no_context")
            }
        }
        val powerManager = context.getSystemService(PowerManager::class.java)
        if (powerManager == null) {
            log("mirror keep-awake failed active=$active error=no_power_manager")
            return Bundle().apply {
                putBoolean("keepAwakeApplied", false)
                putString("keepAwakeError", "no_power_manager")
            }
        }
        synchronized(mirrorKeepAwakeLockGuard) {
            if (active) {
                if (mirrorKeepAwakeLock?.isHeld != true) {
                    @Suppress("DEPRECATION")
                    mirrorKeepAwakeLock = powerManager.newWakeLock(
                        PowerManager.SCREEN_BRIGHT_WAKE_LOCK,
                        MIRROR_KEEP_AWAKE_TAG
                    ).apply {
                        setReferenceCounted(false)
                        acquire(MIRROR_KEEP_AWAKE_TIMEOUT_MS)
                    }
                }
                log("mirror keep-awake acquired uid=${Process.myUid()}")
            } else {
                mirrorKeepAwakeLock?.let { lock ->
                    runCatching { if (lock.isHeld) lock.release() }
                        .onFailure { error ->
                            log("mirror keep-awake release failed: ${error.javaClass.simpleName}: ${error.message}")
                        }
                }
                mirrorKeepAwakeLock = null
                log("mirror keep-awake released")
            }
        }
        return Bundle().apply {
            putBoolean("keepAwakeApplied", true)
            putBoolean("keepAwakeActive", synchronized(mirrorKeepAwakeLockGuard) { mirrorKeepAwakeLock?.isHeld == true })
        }
    }

    private fun handleMirrorGlobalProvider(classLoader: ClassLoader, extras: Bundle): Bundle {
        val requestId = extras.getString("requestId").orEmpty()
        val action = extras.getString("action").orEmpty()
        val injection = injectXiaomiMirrorGlobalViaInputManager(classLoader, action)
        log(
            "mirror global provider requestId=$requestId action=$action " +
                "accepted=${injection.accepted} route=${injection.route} message=${injection.message}"
        )
        return Bundle().apply {
            putBoolean("edgelinkGlobalAccepted", injection.accepted)
            putBoolean("enable", injection.accepted)
            putInt("value", if (injection.accepted) 0 else -1)
            putString("route", injection.route)
            putString("message", injection.message)
            putString("requestId", requestId)
            putString("action", action)
            putInt("reports", 0)
            putString("reportHex", "")
        }
    }

    private fun resolveXiaomiMirrorInputManager(
        classLoader: ClassLoader
    ): Pair<android.hardware.input.InputManager, java.lang.reflect.Method>? {
        val context = xiaomiMirrorApplicationContext(classLoader) ?: return null
        val inputManager = runCatching {
            context.getSystemService(android.hardware.input.InputManager::class.java)
        }.getOrNull() ?: return null
        val injectMethod = runCatching {
            inputManager.javaClass.getMethod(
                "injectInputEvent",
                android.view.InputEvent::class.java,
                Int::class.javaPrimitiveType
            )
        }.getOrNull() ?: return null
        return inputManager to injectMethod
    }

    private fun injectXiaomiMirrorGlobalViaInputManager(
        classLoader: ClassLoader,
        action: String
    ): XiaomiMirrorKeyboardInjectionResult {
        val keyCode = when (action) {
            "back" -> android.view.KeyEvent.KEYCODE_BACK
            "home" -> android.view.KeyEvent.KEYCODE_HOME
            "recents" -> android.view.KeyEvent.KEYCODE_APP_SWITCH
            "power" -> android.view.KeyEvent.KEYCODE_POWER
            else -> return XiaomiMirrorKeyboardInjectionResult(
                accepted = false,
                route = "edgelink.inputmanager.global",
                message = "unsupported global action=$action"
            )
        }
        val resolved = resolveXiaomiMirrorInputManager(classLoader)
            ?: return XiaomiMirrorKeyboardInjectionResult(
                accepted = false,
                route = "edgelink.inputmanager.global",
                message = "input manager unavailable"
            )
        val (inputManager, injectMethod) = resolved
        val downTimeMs = SystemClock.uptimeMillis()
        return runCatching {
            injectXiaomiMirrorKeyEvent(
                inputManager, injectMethod, keyCode, android.view.KeyEvent.ACTION_DOWN,
                downTimeMs, downTimeMs
            )
            injectXiaomiMirrorKeyEvent(
                inputManager, injectMethod, keyCode, android.view.KeyEvent.ACTION_UP,
                downTimeMs, SystemClock.uptimeMillis()
            )
            XiaomiMirrorKeyboardInjectionResult(
                accepted = true,
                route = "edgelink.inputmanager.global",
                message = "injected action=$action keyCode=$keyCode"
            )
        }.getOrElse { error ->
            val cause = error.cause ?: error
            log(
                "mirror global inputmanager injection failed action=$action " +
                    "${cause.javaClass.simpleName}: ${cause.message}"
            )
            XiaomiMirrorKeyboardInjectionResult(
                accepted = false,
                route = "edgelink.inputmanager.global",
                message = "${cause.javaClass.simpleName}:${cause.message.orEmpty()}"
            )
        }
    }

    private var xiaomiMirrorKeyEventObtain12Method: java.lang.reflect.Method? = null
    private var xiaomiMirrorKeyEventObtain12Resolved: Boolean = false

    private fun resolveXiaomiMirrorKeyEventObtain12(): java.lang.reflect.Method? {
        if (!xiaomiMirrorKeyEventObtain12Resolved) {
            xiaomiMirrorKeyEventObtain12Resolved = true
            xiaomiMirrorKeyEventObtain12Method = runCatching {
                android.view.KeyEvent::class.java.getDeclaredMethod(
                    "obtain",
                    Long::class.javaPrimitiveType,
                    Long::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    String::class.java
                )
            }.getOrNull()
        }
        return xiaomiMirrorKeyEventObtain12Method
    }

    private fun injectXiaomiMirrorKeyEvent(
        inputManager: android.hardware.input.InputManager,
        injectMethod: java.lang.reflect.Method,
        keyCode: Int,
        eventAction: Int,
        downTimeMs: Long,
        eventTimeMs: Long,
        metaState: Int = 0
    ) {
        val officialEvent = resolveXiaomiMirrorKeyEventObtain12()?.let { obtain12 ->
            runCatching {
                obtain12.invoke(
                    null,
                    downTimeMs,
                    eventTimeMs,
                    eventAction,
                    keyCode,
                    0,
                    metaState,
                    XIAOMI_MIRROR_INPUT_DEVICE_ID,
                    0,
                    XIAOMI_MIRROR_KEY_EVENT_FLAGS,
                    android.view.InputDevice.SOURCE_KEYBOARD,
                    0,
                    null
                ) as? android.view.KeyEvent
            }.getOrNull()
        }
        val event = officialEvent ?: android.view.KeyEvent(
            downTimeMs,
            eventTimeMs,
            eventAction,
            keyCode,
            0,
            metaState,
            XIAOMI_MIRROR_INPUT_DEVICE_ID,
            0,
            XIAOMI_MIRROR_KEY_EVENT_FLAGS,
            android.view.InputDevice.SOURCE_KEYBOARD
        )
        injectMethod.invoke(inputManager, event, XIAOMI_MIRROR_INJECT_MODE_ASYNC)
    }

    private var xiaomiMirrorObtain15Method: java.lang.reflect.Method? = null
    private var xiaomiMirrorObtain15Resolved: Boolean = false

    private fun resolveXiaomiMirrorObtain15(): java.lang.reflect.Method? {
        if (!xiaomiMirrorObtain15Resolved) {
            xiaomiMirrorObtain15Resolved = true
            xiaomiMirrorObtain15Method = runCatching {
                android.view.MotionEvent::class.java.getDeclaredMethod(
                    "obtain",
                    Long::class.javaPrimitiveType,
                    Long::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Array<android.view.MotionEvent.PointerProperties>::class.java,
                    Array<android.view.MotionEvent.PointerCoords>::class.java,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Float::class.javaPrimitiveType,
                    Float::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType
                )
            }.getOrNull()
        }
        return xiaomiMirrorObtain15Method
    }

    private var xiaomiMirrorSynergyGuardRegistered = false
    private var xiaomiMirrorSynergyGuardLastMode = -1

    private fun installXiaomiMirrorSynergyStatusGuard(classLoader: ClassLoader, source: String) {
        if (xiaomiMirrorSynergyGuardRegistered) return
        val context = xiaomiMirrorApplicationContext(classLoader) ?: return
        val handler = Handler(Looper.getMainLooper())
        runCatching {
            xiaomiMirrorSynergyGuardLastMode =
                Settings.Secure.getInt(context.contentResolver, "synergy_mode", 0)
            context.contentResolver.registerContentObserver(
                Settings.Secure.getUriFor("synergy_mode"),
                false,
                object : android.database.ContentObserver(handler) {
                    override fun onChange(selfChange: Boolean) {
                        val mode = Settings.Secure.getInt(context.contentResolver, "synergy_mode", 0)
                        val previous = xiaomiMirrorSynergyGuardLastMode
                        xiaomiMirrorSynergyGuardLastMode = mode
                        if (previous == 0 && mode == 1) {
                            handler.postDelayed(
                                { resetXiaomiMirrorSynergyStatus(classLoader, "watcher") },
                                XIAOMI_MIRROR_SYNERGY_RESET_DELAY_MS
                            )
                        }
                    }
                }
            )
            xiaomiMirrorSynergyGuardRegistered = true
            log(
                "mirror synergy status guard installed source=$source " +
                    "mode=$xiaomiMirrorSynergyGuardLastMode"
            )
        }.onFailure { error ->
            log(
                "mirror synergy status guard install failed source=$source: " +
                    "${error.javaClass.simpleName}: ${error.message}"
            )
        }
    }

    private fun resetXiaomiMirrorSynergyStatus(classLoader: ClassLoader, source: String) {
        runCatching {
            val context = xiaomiMirrorApplicationContext(classLoader) ?: return@runCatching
            if (Settings.Secure.getInt(context.contentResolver, "synergy_mode", 0) != 1) {
                return@runCatching
            }
            val (inputManager, injectMethod) = resolveXiaomiMirrorInputManager(classLoader)
                ?: return@runCatching
            val nowMs = SystemClock.uptimeMillis()
            val event = obtainXiaomiMirrorSynergyResetEvent(nowMs)
            try {
                injectMethod.invoke(inputManager, event, XIAOMI_MIRROR_INJECT_MODE_ASYNC)
            } finally {
                event.recycle()
            }
            log("mirror synergy status reset injected source=$source")
        }.onFailure { error ->
            val cause = error.cause ?: error
            log(
                "mirror synergy status reset failed source=$source: " +
                    "${cause.javaClass.simpleName}: ${cause.message}"
            )
        }
    }

    private fun obtainXiaomiMirrorSynergyResetEvent(nowMs: Long): android.view.MotionEvent {
        val pointerProperties = arrayOf(
            android.view.MotionEvent.PointerProperties().apply {
                id = 0
                toolType = android.view.MotionEvent.TOOL_TYPE_FINGER
            }
        )
        val pointerCoords = arrayOf(
            android.view.MotionEvent.PointerCoords().apply {
                x = XIAOMI_MIRROR_SYNERGY_RESET_X
                y = XIAOMI_MIRROR_SYNERGY_RESET_Y
                size = 1f
            }
        )
        val officialEvent = resolveXiaomiMirrorObtain15()?.let { obtain15 ->
            runCatching {
                obtain15.invoke(
                    null,
                    nowMs,
                    nowMs,
                    android.view.MotionEvent.ACTION_MOVE,
                    1,
                    pointerProperties,
                    pointerCoords,
                    0,
                    0,
                    1f,
                    1f,
                    XIAOMI_MIRROR_SYNERGY_RESET_DEVICE_ID,
                    0,
                    android.view.InputDevice.SOURCE_TOUCHSCREEN,
                    0,
                    0
                ) as? android.view.MotionEvent
            }.getOrNull()
        }
        return officialEvent ?: android.view.MotionEvent.obtain(
            nowMs,
            nowMs,
            android.view.MotionEvent.ACTION_MOVE,
            XIAOMI_MIRROR_SYNERGY_RESET_X,
            XIAOMI_MIRROR_SYNERGY_RESET_Y,
            0
        ).apply {
            source = android.view.InputDevice.SOURCE_TOUCHSCREEN
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

    private fun readSystemProperty(name: String): String =
        runCatching {
            Class.forName("android.os.SystemProperties")
                .getMethod("get", String::class.java, String::class.java)
                .invoke(null, name, "") as? String
        }.getOrNull().orEmpty()

    private fun boostMiConnectNativeLogging(classLoader: ClassLoader) {
        runCatching {
            val runtimeNative = findTargetClass(
                classLoader,
                "com.xiaomi.continuity.nativelib.ContinuityRuntimeNative"
            )
            runtimeNative.getDeclaredMethod("nativeSetLogLevel", Integer.TYPE).invoke(null, 1)
            log("miconnect: native log level set to 1")
        }.onFailure {
            val cause = it.cause ?: it
            log("miconnect: set native log level failed: ${cause.message}")
        }
    }

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

        private const val TRUST_BIND_ACTION = "com.edgelink.mitrust.BIND"
        private const val TRUST_SHARED_AUTH_SERVICE = "vendor.xiaomi.hardware.misauth.IMiSharedAuth/default"
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
        private const val MI_CONNECT_PERMISSION_CHECKER = "com.xiaomi.continuity.util.PermissionChecker"
        private const val XIAOMI_MIRROR_CALL_PROVIDER = "com.xiaomi.mirror.provider.CallProvider"
        private const val MIRROR_KEEP_AWAKE_TAG = "EdgeLink:MirrorKeepAwake"
        private const val MIRROR_KEEP_AWAKE_TIMEOUT_MS = 8 * 60 * 60 * 1000L
        private const val XIAOMI_MIRROR_APPLICATION = "com.xiaomi.mirror.Mirror"
        private const val XIAOMI_MIRROR_MESSAGE_MANAGER = "com.xiaomi.mirror.message.MessageManagerImpl"
        private const val XIAOMI_MIRROR_SCREEN_CONFIGURATION_MESSAGE =
            "com.xiaomi.mirror.message.ScreenConfigurationChangedMessage"
        private const val XIAOMI_MIRROR_MESSAGE_CONVERT = "com.xiaomi.mirror.message.MessageConvert"
        private const val XIAOMI_MIRROR_SCREEN_CONFIGURATION_TYPE = 5
        private const val XIAOMI_MIRROR_MAIN_SCREEN_ID = 0
        private const val XIAOMI_MIRROR_INPUT_DEVICE_ID = -100
        private const val XIAOMI_MIRROR_SYNERGY_RESET_DEVICE_ID = 0
        private const val XIAOMI_MIRROR_SYNERGY_RESET_X = 500f
        private const val XIAOMI_MIRROR_SYNERGY_RESET_Y = 300f
        private const val XIAOMI_MIRROR_SYNERGY_RESET_DELAY_MS = 150L
        private const val XIAOMI_MIRROR_KEY_EVENT_FLAGS = 0x800008
        private const val XIAOMI_MIRROR_INJECT_MODE_ASYNC = 0
        private const val XIAOMI_MIRROR_UHID_GID = 3011
        private const val XIAOMI_MIRROR_WIFI_OPEN_CONTROLLER = "p2.x"
        private const val XIAOMI_MIRROR_WIFI_OPEN_CALLBACK = "p2.x\$c"
        private const val XIAOMI_MIRROR_WIFI_OPEN_TASK = "p2.x\$e"
    }
}
