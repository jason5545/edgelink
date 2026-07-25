package com.edgelink.app

import android.util.Log
import io.github.libxposed.api.XposedModule
import io.github.libxposed.api.XposedModuleInterface.HotReloadedParam
import io.github.libxposed.api.XposedModuleInterface.HotReloadingParam
import io.github.libxposed.api.XposedModuleInterface.ModuleLoadedParam
import io.github.libxposed.api.XposedModuleInterface.PackageReadyParam
import io.github.libxposed.api.XposedModuleInterface.SystemServerStartingParam

class EdgeLinkXposedModule : XposedModule() {
    private var processName: String = ""
    private var hook: MiLinkPrivilegeXposedHook? = null

    override fun onModuleLoaded(param: ModuleLoadedParam) {
        processName = param.processName
        hook = MiLinkPrivilegeXposedHook(this)
        log(
            Log.INFO,
            MiLinkPrivilegeXposedHook.LOG_TAG,
            "module loaded process=$processName systemServer=${param.isSystemServer} " +
                "framework=$frameworkName $frameworkVersion api=$apiVersion"
        )
    }

    override fun onSystemServerStarting(param: SystemServerStartingParam) {
        hook?.installForPackage(
            packageName = MiLinkPrivilegeHookPolicy.ANDROID_PACKAGE,
            processName = processName.ifEmpty { MiLinkPrivilegeHookPolicy.SYSTEM_SERVER_PROCESS },
            classLoader = param.classLoader,
            systemServer = true
        )
    }

    override fun onPackageReady(param: PackageReadyParam) {
        hook?.installForPackage(
            packageName = param.packageName,
            processName = processName,
            classLoader = param.classLoader,
            systemServer = false
        )
    }

    override fun onHotReloading(param: HotReloadingParam): Boolean {
        val current = hook ?: return true
        return runCatching {
            param.setSavedInstanceState(current.buildSavedState())
            current.shutdown()
            log(Log.INFO, MiLinkPrivilegeXposedHook.LOG_TAG, "hot reload accepted process=$processName")
            true
        }.getOrElse { error ->
            log(
                Log.ERROR,
                MiLinkPrivilegeXposedHook.LOG_TAG,
                "hot reload rejected process=$processName: ${error.message}"
            )
            false
        }
    }

    override fun onHotReloaded(param: HotReloadedParam) {
        processName = param.processName
        param.oldHookHandles.forEach { it.unhook() }
        val newHook = MiLinkPrivilegeXposedHook(this)
        hook = newHook
        val targets = param.savedInstanceState as? ArrayList<*>
        log(
            Log.INFO,
            MiLinkPrivilegeXposedHook.LOG_TAG,
            "hot reloaded process=$processName targets=${targets?.size ?: 0}"
        )
        targets?.forEach { entry ->
            val map = entry as? Map<*, *> ?: return@forEach
            val classLoader = map["classLoader"] as? ClassLoader ?: return@forEach
            newHook.installForPackage(
                packageName = map["packageName"] as? String,
                processName = map["processName"] as? String,
                classLoader = classLoader,
                systemServer = map["systemServer"] as? Boolean == true
            )
        }
    }
}
