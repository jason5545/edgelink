package com.edgelink.app

import de.robv.android.xposed.XposedHelpers
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

object MiShareTrustInjection {
    const val SERVICE_NAME = "miLyraShare"
    const val SERVICE_NAME_BASIC = "miShareBasic"
    val KNOWN_SERVICE_NAMES = setOf(SERVICE_NAME, SERVICE_NAME_BASIC)

    private const val CONFIG_PATH = "/data/local/tmp/edgelink-mishare-inject.json"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_DEVICE_ID = "device_id"
    private const val KEY_DEVICE_NAME = "device_name"
    private const val KEY_DEVICE_TYPE = "device_type"
    private const val KEY_MEDIUM_TYPES = "medium_types"
    private const val KEY_TRUSTED_TYPES = "trusted_types"
    private const val KEY_SERVICES = "services"
    private const val KEY_SERVICE_NAME = "service_name"
    private const val KEY_SERVICE_PACKAGE = "service_package"
    private const val KEY_SERVICE_DATA_B64 = "service_data_b64"

    private const val DEFAULT_DEVICE_TYPE = 14
    private const val DEFAULT_MEDIUM_TYPES = 128
    private const val DEFAULT_TRUSTED_TYPES = 1
    private const val DEFAULT_SERVICE_PACKAGE = "com.edgelink.mac"
    private const val INJECT_INTERVAL_SECONDS = 10L

    private val lock = Any()
    private val listenersByService = mutableMapOf<String, MutableSet<Any>>()
    private val injectorStarted = AtomicBoolean(false)
    private val scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "edgelink-mishare-inject").apply { isDaemon = true }
    }

    @Volatile
    private var lastLoggedConfig: String? = null

    fun registerListener(classLoader: ClassLoader, serviceName: String, listener: Any, logger: (String) -> Unit) {
        synchronized(lock) {
            listenersByService.getOrPut(serviceName) { mutableSetOf() } += listener
        }
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

    private data class ServiceSpec(val name: String, val packageName: String, val data: ByteArray?)

    private fun decodeServiceData(encoded: String): ByteArray? = encoded.trim()
        .takeIf { it.isNotEmpty() }
        ?.let { runCatching { android.util.Base64.decode(it, android.util.Base64.DEFAULT) }.getOrNull() }

    private fun parseServiceSpecs(config: JSONObject): List<ServiceSpec> {
        val specs = mutableListOf<ServiceSpec>()
        val array = config.optJSONArray(KEY_SERVICES)
        if (array != null) {
            for (index in 0 until array.length()) {
                val entry = array.optJSONObject(index) ?: continue
                val name = entry.optString(KEY_SERVICE_NAME).trim()
                if (name.isEmpty()) {
                    continue
                }
                specs += ServiceSpec(
                    name,
                    entry.optString(KEY_SERVICE_PACKAGE).trim().ifEmpty { DEFAULT_SERVICE_PACKAGE },
                    decodeServiceData(entry.optString(KEY_SERVICE_DATA_B64))
                )
            }
        }
        if (specs.isEmpty()) {
            specs += ServiceSpec(
                config.optString(KEY_SERVICE_NAME).trim().ifEmpty { SERVICE_NAME },
                config.optString(KEY_SERVICE_PACKAGE).trim().ifEmpty { DEFAULT_SERVICE_PACKAGE },
                decodeServiceData(config.optString(KEY_SERVICE_DATA_B64))
            )
        }
        return specs
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
        val serviceSpecs = parseServiceSpecs(config)

        val listenerSnapshot: Map<String, List<Any>> = synchronized(lock) {
            listenersByService.mapValues { (_, value) -> value.toList() }
        }

        val servicesSummary = serviceSpecs.joinToString(",") { it.name }
        val listenersSummary = listenerSnapshot.entries.joinToString(",") { "${it.key}:${it.value.size}" }
        val snapshot = "$deviceId|$deviceName|$deviceType|$mediumTypes|$trustedTypes|$servicesSummary|$listenersSummary"
        logOnce(logger, "config-$snapshot") {
            "injecting deviceId=$deviceId name=$deviceName type=$deviceType " +
                "medium=$mediumTypes trusted=$trustedTypes services=$servicesSummary " +
                "listeners=$listenersSummary"
        }

        val trustedDeviceInfo = buildTrustedDeviceInfo(
            classLoader, deviceId, deviceName, deviceType, mediumTypes, trustedTypes
        ) ?: return

        val specsByName = serviceSpecs.associateBy { it.name }
        for ((serviceName, serviceListeners) in listenerSnapshot) {
            val spec = specsByName[serviceName]
                ?: ServiceSpec(serviceName, DEFAULT_SERVICE_PACKAGE, null)
            val businessServiceInfo = buildBusinessServiceInfo(
                classLoader, spec.name, spec.packageName, spec.data
            ) ?: return
            for (listener in serviceListeners) {
                runCatching {
                    XposedHelpers.callMethod(listener, "onServiceOnline", businessServiceInfo, trustedDeviceInfo)
                }.onFailure {
                    logger("onServiceOnline call failed service=$serviceName listener=$listener error=${it.message}")
                }
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
