package com.edgelink.app

import android.content.Context
import android.content.ContentProvider
import android.os.Binder
import android.os.Bundle
import android.os.Parcelable
import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage
import java.util.ArrayList
import java.util.HashMap

internal object MiLinkPrivilegeHookPolicy {
    const val EDGE_LINK_PACKAGE = "com.edgelink.app"
    const val MILINK_PACKAGE = "com.milink.service"
    const val MILINK_MAIN_PROCESS = "com.milink.service"
    const val MILINK_RUNTIME_PROCESS = "com.milink.runtime"
    const val XIAOMI_MIRROR_PACKAGE = "com.xiaomi.mirror"
    const val XIAOMI_MIRROR_PROCESS = "com.xiaomi.mirror"
    const val MIRROR_FAKE_REMOTE_PROPERTY = "debug.edgelink.mirror_fake_remote"
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
            shouldHookXiaomiMirror(packageName, processName)

    fun shouldHookRuntime(packageName: String?, processName: String?): Boolean =
        packageName == MILINK_PACKAGE && processName == MILINK_RUNTIME_PROCESS

    fun shouldHookMainService(packageName: String?, processName: String?): Boolean =
        packageName == MILINK_PACKAGE && processName == MILINK_MAIN_PROCESS

    fun shouldHookXiaomiMirror(packageName: String?, processName: String?): Boolean =
        packageName == XIAOMI_MIRROR_PACKAGE && processName == XIAOMI_MIRROR_PROCESS

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
}

class MiLinkPrivilegeXposedHook : IXposedHookLoadPackage {
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
                        val mode = currentFakeMirrorRemoteMode() ?: return
                        val method = param.args.getOrNull(0) as? String ?: return
                        if (method == "queryRemoteDevices" || method == "queryRemoteDevice") {
                            prepareFakeMirrorTerminal(classLoader, mode)
                        }
                    }

                    override fun afterHookedMethod(param: MethodHookParam) {
                        val mode = currentFakeMirrorRemoteMode() ?: return
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
                        val mode = currentFakeMirrorRemoteMode() ?: return
                        val deviceId = param.args.getOrNull(0) as? String
                        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(deviceId)) {
                            return
                        }
                        param.setResult(prepareFakeMirrorTerminal(classLoader, mode))
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
                        val mode = currentFakeMirrorRemoteMode() ?: return
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
                        val mode = currentFakeMirrorRemoteMode() ?: return
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
    }
}
