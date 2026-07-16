package com.edgelink.app

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.IInterface
import android.os.Parcel
import com.xiaomi.mirror.RemoteDeviceInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

object AndroidMiLinkPhoneContinuityBridge {
    private const val authority = "com.xiaomi.mirror.callprovider"
    private val providerUri: Uri = Uri.parse("content://$authority")
    private const val callRelayDescriptor = "com.xiaomi.mirror.ICallRelayService"

    suspend fun probe(context: Context): PhoneContinuityProbeResult =
        withContext(Dispatchers.IO) {
            val resolver = context.applicationContext.contentResolver
            val steps = mutableListOf<String>()
            var callRelayServiceOk = false
            var mediaRelayCallbackOk = false
            var remoteDeviceCount = 0
            var mediaRelayCandidateCount = 0

            val aliveBundle = runProviderStep(steps, "aliveBundle") {
                resolver.callProvider("getAliveBinder")
            }
            steps += "aliveBundleKeys=${aliveBundle?.keySummary().orEmpty()}"
            val aliveBinder = aliveBundle?.getBinder("binder")
            if (aliveBinder != null) {
                steps += "aliveDescriptor=${aliveBinder.descriptorStep()}"
            }
            delay(MIRROR_MAIN_SERVICE_WARMUP_MS)

            val callRelayBundle = runProviderStep(steps, "callRelayBundle") {
                resolver.callProviderWithRetry("getCallRelayService")
            }
            steps += "callRelayBundleKeys=${callRelayBundle?.keySummary().orEmpty()}"
            val callRelayBinder = callRelayBundle?.getBinder("binder")
            if (callRelayBinder != null) {
                val descriptor = callRelayBinder.descriptorStep()
                steps += "callRelayDescriptor=$descriptor"
                callRelayServiceOk = descriptor == callRelayDescriptor
            }

            val remoteDevicesById = linkedMapOf<String, RemoteDeviceInfo>()
            val currentRemoteDevice = runProviderStep(steps, "remoteDevice:current") {
                resolver.queryCurrentRemoteDevice()
            }
            if (currentRemoteDevice != null) {
                steps += "remoteDevice:current:sample=${currentRemoteDevice.compactSummary()}"
                remoteDevicesById[currentRemoteDevice.id ?: currentRemoteDevice.deviceId ?: currentRemoteDevice.compactSummary()] =
                    currentRemoteDevice
            }
            for (query in remoteDeviceQueries) {
                val devices = runProviderStep(steps, "remoteDevices:${query.label}") {
                    resolver.queryRemoteDevices(
                        manufacturer = query.manufacturer,
                        platform = query.platform
                    )
                }.orEmpty()
                val queryMediaRelayCandidates = devices.count {
                    it.isMediaRelay != RemoteDeviceInfo.MEDIA_RELAY_NOT_SUPPORT
                }
                steps += "remoteDevices:${query.label}:count=${devices.size}:mediaRelayCandidates=$queryMediaRelayCandidates"
                if (devices.isNotEmpty()) {
                    steps += "remoteDevices:${query.label}:sample=${devices.take(3).joinToString("|") { it.compactSummary() }}"
                }
                for (device in devices) {
                    remoteDevicesById[device.id ?: device.deviceId ?: device.compactSummary()] = device
                }
            }
            if (remoteDevicesById.isNotEmpty()) {
                val devices = remoteDevicesById.values.toList()
                remoteDeviceCount = devices.size
                mediaRelayCandidateCount = devices.count { it.isMediaRelay != RemoteDeviceInfo.MEDIA_RELAY_NOT_SUPPORT }
                steps += "remoteDevicesUnique=${devices.size}:mediaRelayCandidates=$mediaRelayCandidateCount"
                for (deviceId in devices.mapNotNull { it.id }.distinct().take(3)) {
                    val device = runProviderStep(steps, "remoteDevice:$deviceId") {
                        resolver.queryRemoteDevice(deviceId)
                    }
                    if (device != null) {
                        steps += "remoteDevice:$deviceId:sample=${device.compactSummary()}"
                    }
                }
            }

            val mediaRelayCallback = MediaRelayCallbackBinder { deviceId, volume ->
                EdgeLinkLog.info("xiaomi.phone.media_relay_volume deviceId=$deviceId volume=$volume")
            }
            val registerResult = runProviderStep(steps, "registerMediaRelayCallback") {
                resolver.callProviderWithRetry(
                    "registerMediaRelayCallback",
                    Bundle().apply { putBinder("callback", mediaRelayCallback) }
                )
            }
            steps += "registerMediaRelayCallbackKeys=${registerResult?.keySummary().orEmpty()}"
            val registerValue = registerResult?.valueInt()
            if (registerValue != null) {
                mediaRelayCallbackOk = registerValue == 0
                steps += "mediaRelayCallbackValue=$registerValue"
            }
            if (registerResult != null) {
                runProviderStep(steps, "unregisterMediaRelayCallback") {
                    resolver.callProvider(
                        "unregisterMediaRelayCallback",
                        Bundle().apply { putBinder("callback", mediaRelayCallback) }
                    )
                }
            }

            val success = callRelayServiceOk || mediaRelayCallbackOk || remoteDeviceCount > 0
            val message = "MiLink phone continuity ${if (success) "ok" else "failed"}: " +
                steps.joinToString()
            EdgeLinkLog.info(
                "xiaomi.phone.continuity_probe success=$success callRelay=$callRelayServiceOk " +
                    "mediaRelayCallback=$mediaRelayCallbackOk remoteDevices=$remoteDeviceCount " +
                    "mediaRelayCandidates=$mediaRelayCandidateCount"
            )
            PhoneContinuityProbeResult(
                success = success,
                callRelayServiceOk = callRelayServiceOk,
                mediaRelayCallbackOk = mediaRelayCallbackOk,
                remoteDeviceCount = remoteDeviceCount,
                mediaRelayCandidateCount = mediaRelayCandidateCount,
                message = message
            )
        }

    private suspend fun <T> runProviderStep(
        steps: MutableList<String>,
        name: String,
        block: suspend () -> T
    ): T? {
        return try {
            val value = block()
            steps += "$name=${if (value == null) "null" else "ok"}"
            value
        } catch (error: Throwable) {
            steps += "$name=${error.javaClass.simpleName}:${error.message}"
            null
        }
    }

    private fun ContentResolver.callProvider(method: String, extras: Bundle? = null): Bundle? =
        if (Build.VERSION.SDK_INT >= 29) {
            call(authority, method, null, extras)
        } else {
            call(providerUri, method, null, extras)
        }

    private suspend fun ContentResolver.callProviderWithRetry(
        method: String,
        extras: Bundle? = null
    ): Bundle? {
        repeat(PROVIDER_READY_RETRY_COUNT) { attempt ->
            val result = callProvider(method, extras)
            if (result != null || attempt == PROVIDER_READY_RETRY_COUNT - 1) {
                return result
            }
            delay(PROVIDER_READY_RETRY_DELAY_MS)
        }
        return null
    }

    private fun ContentResolver.queryRemoteDevices(
        manufacturer: String? = null,
        platform: String? = null
    ): List<RemoteDeviceInfo> {
        val result = callProvider(
            "queryRemoteDevices",
            Bundle().apply {
                if (manufacturer != null) {
                    putString("remoteDeviceManufacturer", manufacturer)
                }
                if (platform != null) {
                    putString("device_platform", platform)
                }
            }
        ) ?: return emptyList()
        result.classLoader = RemoteDeviceInfo::class.java.classLoader
        @Suppress("DEPRECATION")
        return result.getParcelableArrayList<RemoteDeviceInfo>("remoteDevices").orEmpty()
    }

    private fun ContentResolver.queryRemoteDevice(deviceId: String): RemoteDeviceInfo? {
        val result = callProvider(
            "queryRemoteDevice",
            Bundle().apply {
                putString("remoteDeviceId", deviceId)
            }
        ) ?: return null
        result.classLoader = RemoteDeviceInfo::class.java.classLoader
        @Suppress("DEPRECATION")
        return result.getParcelable("remoteDevice")
    }

    private fun ContentResolver.queryCurrentRemoteDevice(): RemoteDeviceInfo? {
        val result = callProvider("queryRemoteDevice", Bundle()) ?: return null
        result.classLoader = RemoteDeviceInfo::class.java.classLoader
        @Suppress("DEPRECATION")
        return result.getParcelable("remoteDevice")
    }

    private fun IBinder.descriptorStep(): String =
        runCatching { interfaceDescriptor.orEmpty() }
            .getOrElse { error -> "${error.javaClass.simpleName}:${error.message}" }

    private fun Bundle.valueInt(): Int? =
        when {
            containsKey("value") -> getInt("value")
            containsKey("result") -> getInt("result")
            else -> null
        }

    private fun RemoteDeviceInfo.compactSummary(): String =
        "id=${id ?: "-"} platform=${platform ?: "-"} relay=$isMediaRelay name=${displayName ?: "-"}"

    private fun Bundle.keySummary(): String =
        keySet().sorted().joinToString("|") { key ->
            "$key=${valueSummary(get(key))}"
        }

    private fun valueSummary(value: Any?): String =
        when (value) {
            null -> "null"
            is IBinder -> "binder:${value.descriptorStep()}"
            is ArrayList<*> -> "list:${value.size}"
            else -> value.toString()
        }

    private class MediaRelayCallbackBinder(
        private val onVolumeChanged: (deviceId: String, volume: Int) -> Unit
    ) : Binder(), IInterface {
        init {
            attachInterface(this, descriptor)
        }

        override fun asBinder(): IBinder = this

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == IBinder.INTERFACE_TRANSACTION) {
                reply?.writeString(descriptor)
                return true
            }
            if (code == transactionOnVolumeChanged) {
                data.enforceInterface(descriptor)
                val deviceId = data.readString().orEmpty()
                val volume = data.readInt()
                onVolumeChanged(deviceId, volume)
                return true
            }
            return super.onTransact(code, data, reply, flags)
        }

        private companion object {
            private const val descriptor = "com.xiaomi.mirror.IMediaRelayCallback"
            private const val transactionOnVolumeChanged = 1
        }
    }

    private data class RemoteDeviceQuery(
        val label: String,
        val manufacturer: String? = null,
        val platform: String? = null
    )

    private val remoteDeviceQueries = listOf(
        RemoteDeviceQuery(label = "all"),
        RemoteDeviceQuery(label = "xiaomi", manufacturer = RemoteDeviceInfo.MANUFACTURER_XIAOMI),
        RemoteDeviceQuery(label = "other", manufacturer = RemoteDeviceInfo.MANUFACTURER_OTHER),
        RemoteDeviceQuery(label = "windows", platform = RemoteDeviceInfo.PLATFORM_WINDOWS),
        RemoteDeviceQuery(label = "mac", platform = "Mac"),
        RemoteDeviceQuery(label = "commonPc", platform = "CommonPc"),
        RemoteDeviceQuery(label = "androidPad", platform = RemoteDeviceInfo.PLATFORM_ANDROID_PAD),
        RemoteDeviceQuery(label = "androidPadCar", platform = RemoteDeviceInfo.PLATFORM_ANDROID_PAD_CAR)
    )

    private const val MIRROR_MAIN_SERVICE_WARMUP_MS = 750L
    private const val PROVIDER_READY_RETRY_COUNT = 4
    private const val PROVIDER_READY_RETRY_DELAY_MS = 250L
}

data class PhoneContinuityProbeResult(
    val success: Boolean,
    val callRelayServiceOk: Boolean,
    val mediaRelayCallbackOk: Boolean,
    val remoteDeviceCount: Int,
    val mediaRelayCandidateCount: Int,
    val message: String
)
