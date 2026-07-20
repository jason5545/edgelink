package com.edgelink.app

import de.robv.android.xposed.XposedHelpers
import java.io.File
import java.util.Collections
import java.util.WeakHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

object MiShareTrustInjection {
    const val SERVICE_NAME = "miLyraShare"
    private const val CONFIG_PATH = "/data/local/tmp/edgelink-mishare-inject.json"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_DEVICE_ID = "device_id"
    private const val KEY_DEVICE_NAME = "device_name"
    private const val KEY_DEVICE_TYPE = "device_type"
    private const val KEY_MEDIUM_TYPES = "medium_types"
    private const val KEY_TRUSTED_TYPES = "trusted_types"
    private const val KEY_SERVICE_NAME = "service_name"
    private const val KEY_SERVICE_PACKAGE = "service_package"
    private const val KEY_SERVICE_DATA_B64 = "service_data_b64"

    private const val DEFAULT_DEVICE_TYPE = 14
    private const val DEFAULT_MEDIUM_TYPES = 128
    private const val DEFAULT_TRUSTED_TYPES = 1
    private const val DEFAULT_SERVICE_PACKAGE = "com.edgelink.mac"
    private const val INJECT_INTERVAL_SECONDS = 10L

    private val listeners = Collections.newSetFromMap(WeakHashMap<Any, Boolean>())
    private val injectorStarted = AtomicBoolean(false)
    private val scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "edgelink-mishare-inject").apply { isDaemon = true }
    }

    @Volatile
    private var lastLoggedConfig: String? = null

    fun registerListener(classLoader: ClassLoader, listener: Any, logger: (String) -> Unit) {
        listeners += listener
        if (injectorStarted.compareAndSet(false, true)) {
            scheduler.scheduleWithFixedDelay(
                {
                    runCatching { injectOnce(classLoader, logger) }
                        .onFailure { logger("inject failed: ${it.message}") }
                },
                0,
                INJECT_INTERVAL_SECONDS,
                TimeUnit.SECONDS
            )
        }
    }

    private fun injectOnce(classLoader: ClassLoader, logger: (String) -> Unit) {
        val configFile = File(CONFIG_PATH)
        val config = runCatching {
            if (!configFile.isFile) {
                return
            }
            JSONObject(configFile.readText())
        }.getOrElse {
            logOnce(logger, "config-read-failed-${it.javaClass.simpleName}") {
                "config read failed path=$CONFIG_PATH error=${it.message}"
            }
            return
        }
        if (!config.optBoolean(KEY_ENABLED, false)) {
            return
        }
        val deviceId = config.optString(KEY_DEVICE_ID).trim()
        if (deviceId.isEmpty()) {
            logOnce(logger, "config-missing-device-id") { "enabled but device_id is empty" }
            return
        }
        val deviceName = config.optString(KEY_DEVICE_NAME).trim()
        val deviceType = config.optInt(KEY_DEVICE_TYPE, DEFAULT_DEVICE_TYPE)
        val mediumTypes = config.optInt(KEY_MEDIUM_TYPES, DEFAULT_MEDIUM_TYPES)
        val trustedTypes = config.optInt(KEY_TRUSTED_TYPES, DEFAULT_TRUSTED_TYPES)
        val serviceName = config.optString(KEY_SERVICE_NAME).trim().ifEmpty { SERVICE_NAME }
        val servicePackage = config.optString(KEY_SERVICE_PACKAGE).trim().ifEmpty { DEFAULT_SERVICE_PACKAGE }
        val serviceData = config.optString(KEY_SERVICE_DATA_B64).trim()
            .takeIf { it.isNotEmpty() }
            ?.let { runCatching { android.util.Base64.decode(it, android.util.Base64.DEFAULT) }.getOrNull() }

        val snapshot = listOf(deviceId, deviceName, deviceType, mediumTypes, trustedTypes, serviceName)
            .joinToString()
        logOnce(logger, "config-$snapshot") {
            "injecting deviceId=$deviceId name=$deviceName type=$deviceType " +
                "medium=$mediumTypes trusted=$trustedTypes service=$serviceName " +
                "listeners=${listeners.size}"
        }

        val trustedDeviceInfo = buildTrustedDeviceInfo(
            classLoader, deviceId, deviceName, deviceType, mediumTypes, trustedTypes
        ) ?: return
        val businessServiceInfo = buildBusinessServiceInfo(
            classLoader, serviceName, servicePackage, serviceData
        ) ?: return

        for (listener in listeners) {
            runCatching {
                XposedHelpers.callMethod(listener, "onServiceOnline", businessServiceInfo, trustedDeviceInfo)
            }.onFailure {
                logger("onServiceOnline call failed listener=$listener error=${it.message}")
            }
        }
    }

    private fun buildTrustedDeviceInfo(
        classLoader: ClassLoader,
        deviceId: String,
        deviceName: String,
        deviceType: Int,
        mediumTypes: Int,
        trustedTypes: Int
    ): Any? {
        val clazz = runCatching {
            XposedHelpers.findClass("com.xiaomi.continuity.networking.TrustedDeviceInfo", classLoader)
        }.getOrNull() ?: return null
        val instance = runCatching { clazz.getDeclaredConstructor().newInstance() }.getOrNull() ?: return null
        XposedHelpers.callMethod(instance, "setDeviceId", deviceId)
        XposedHelpers.callMethod(instance, "setDeviceName", deviceName)
        XposedHelpers.callMethod(instance, "setDeviceType", deviceType)
        XposedHelpers.callMethod(instance, "setMediumTypes", mediumTypes)
        XposedHelpers.callMethod(instance, "setTrustedTypes", trustedTypes)
        return instance
    }

    private fun buildBusinessServiceInfo(
        classLoader: ClassLoader,
        serviceName: String,
        servicePackage: String,
        serviceData: ByteArray?
    ): Any? {
        val clazz = runCatching {
            XposedHelpers.findClass("com.xiaomi.continuity.networking.BusinessServiceInfo", classLoader)
        }.getOrNull() ?: return null
        val instance = runCatching { clazz.getDeclaredConstructor().newInstance() }.getOrNull() ?: return null
        XposedHelpers.callMethod(instance, "setServiceName", serviceName)
        XposedHelpers.callMethod(instance, "setPackageName", servicePackage)
        if (serviceData != null) {
            XposedHelpers.callMethod(instance, "setServiceData", serviceData)
        }
        return instance
    }

    private fun logOnce(logger: (String) -> Unit, key: String, message: () -> String) {
        if (lastLoggedConfig == key) {
            return
        }
        lastLoggedConfig = key
        logger(message())
    }
}
