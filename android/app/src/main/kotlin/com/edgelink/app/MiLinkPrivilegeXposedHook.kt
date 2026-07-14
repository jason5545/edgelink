package com.edgelink.app

import android.content.Context
import android.content.ContentProvider
import android.os.Binder
import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage

internal object MiLinkPrivilegeHookPolicy {
    const val EDGE_LINK_PACKAGE = "com.edgelink.app"
    const val MILINK_PACKAGE = "com.milink.service"
    const val MILINK_MAIN_PROCESS = "com.milink.service"
    const val MILINK_RUNTIME_PROCESS = "com.milink.runtime"
    const val XIAOMI_MIRROR_PACKAGE = "com.xiaomi.mirror"
    const val XIAOMI_MIRROR_PROCESS = "com.xiaomi.mirror"

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

    private fun log(message: String) {
        XposedBridge.log("EdgeLinkMiLinkHook: $message")
    }

    private companion object {
        private const val MILINK_BASE_CLIENT_SERVICE = "com.milink.client.BaseClientService"
        private const val MILINK_PRIVILEGED_PACKAGE_MANAGER = "com.milink.base.utils.p"
        private const val XIAOMI_MIRROR_CALL_PROVIDER = "com.xiaomi.mirror.provider.CallProvider"
    }
}
