package com.edgelink.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.IInterface
import android.os.Parcel
import android.os.Parcelable
import android.os.RemoteException
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class AndroidMiShareServiceClient(
    context: Context
) {
    private val appContext = context.applicationContext

    suspend fun discover(timeoutMs: Long = defaultDiscoverTimeoutMs): MiShareDiscoveryResult {
        val boundedTimeoutMs = timeoutMs.coerceIn(1_000L, maxDiscoverTimeoutMs)
        val bound = bind()
        val callback = DiscoveryCallback()
        val stateBefore = runCatching { bound.binder.getState() }.getOrNull()
        return try {
            val intent = Intent().putExtra("UI_MISHARE_SUPPORT_APPLE_STYLE", true)
            bound.binder.discoverWithIntent(callback, intent)
            delay(boundedTimeoutMs)
            runCatching { bound.binder.stopDiscover(callback) }
            MiShareDiscoveryResult(
                stateBefore = stateBefore,
                devices = callback.devicesSnapshot(),
                lostDeviceIds = callback.lostSnapshot()
            )
        } finally {
            runCatching { appContext.unbindService(bound.connection) }
        }
    }

    private suspend fun bind(): BoundMiShareService =
        withTimeout(bindTimeoutMs) {
            suspendCancellableCoroutine { continuation ->
                val intent = Intent().setClassName(miSharePackage, miShareServiceClass)
                val connection = object : ServiceConnection {
                    override fun onServiceConnected(name: ComponentName, service: IBinder) {
                        if (continuation.isActive) {
                            continuation.resume(BoundMiShareService(service, this))
                        }
                    }

                    override fun onServiceDisconnected(name: ComponentName) = Unit

                    override fun onNullBinding(name: ComponentName) {
                        if (continuation.isActive) {
                            continuation.resumeWithException(IllegalStateException("MiShareService null binding"))
                        }
                    }
                }
                val bound = runCatching {
                    appContext.bindService(intent, connection, Context.BIND_AUTO_CREATE)
                }.getOrElse { error ->
                    continuation.resumeWithException(error)
                    return@suspendCancellableCoroutine
                }
                if (!bound) {
                    continuation.resumeWithException(IllegalStateException("MiShareService bind=false"))
                    return@suspendCancellableCoroutine
                }
                continuation.invokeOnCancellation {
                    runCatching { appContext.unbindService(connection) }
                }
            }
        }

    private class DiscoveryCallback : Binder(), IInterface {
        private val devices = ConcurrentHashMap<String, MiShareRemoteDevice>()
        private val lostDeviceIds = ConcurrentHashMap.newKeySet<String>()

        init {
            attachInterface(this, discoverCallbackDescriptor)
        }

        override fun asBinder(): IBinder = this

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == IBinder.INTERFACE_TRANSACTION) {
                reply?.writeString(discoverCallbackDescriptor)
                return true
            }
            if (code !in 1..16_777_215) {
                return super.onTransact(code, data, reply, flags)
            }
            data.enforceInterface(discoverCallbackDescriptor)
            return when (code) {
                transactionOnDeviceUpdated -> {
                    val device = data.readRemoteDevice()
                    if (device != null) {
                        devices[device.deviceId] = device
                        lostDeviceIds.remove(device.deviceId)
                        EdgeLinkLog.info(
                            "xiaomi.mishare.binder_device deviceId=${device.deviceId} " +
                                "name=${device.displayName.orEmpty().forSingleLineLog()} " +
                                "model=${device.model.orEmpty().forSingleLineLog()} " +
                                "source=${device.source.orEmpty()} service=${device.serviceId.orEmpty()} " +
                                "extras=${device.extrasSummary().forSingleLineLog()}"
                        )
                    }
                    true
                }
                transactionOnDeviceLost -> {
                    val deviceId = data.readString().orEmpty()
                    if (deviceId.isNotEmpty()) {
                        devices.remove(deviceId)
                        lostDeviceIds.add(deviceId)
                    }
                    true
                }
                else -> super.onTransact(code, data, reply, flags)
            }
        }

        fun devicesSnapshot(): List<MiShareRemoteDevice> =
            devices.values.sortedBy { it.displayName ?: it.deviceId }

        fun lostSnapshot(): List<String> =
            lostDeviceIds.sorted()
    }

    private data class BoundMiShareService(
        val binder: IBinder,
        val connection: ServiceConnection
    )

    data class MiShareDiscoveryResult(
        val stateBefore: Int?,
        val devices: List<MiShareRemoteDevice>,
        val lostDeviceIds: List<String>
    )

    data class MiShareRemoteDevice(
        val deviceId: String,
        val displayName: String?,
        val model: String?,
        val manufacture: String?,
        val serviceId: String?,
        val source: String?,
        val rawExtras: Map<String, String>
    ) {
        fun compactSummary(): String {
            val name = displayName ?: model ?: "unknown"
            val service = serviceId?.let { " service=$it" }.orEmpty()
            val sourceText = source?.let { " source=$it" }.orEmpty()
            return "$deviceId $name$service$sourceText"
        }

        fun diagnosticSummary(): String =
            "${compactSummary()} extras=${extrasSummary()}"

        fun extrasSummary(): String =
            rawExtras.toSortedMap()
                .entries
                .joinToString(",") { (key, value) -> "$key=$value" }
                .take(1_200)

        fun looksLikeMac(): Boolean {
            val text = listOfNotNull(displayName, model, manufacture, rawExtras["nickname"])
                .joinToString(" ")
                .lowercase()
            return text.contains("mac") || text.contains("macbook") || text.contains("edgelink")
        }
    }

    private companion object {
        const val miSharePackage = "com.miui.mishare.connectivity"
        const val miShareServiceClass = "com.miui.mishare.connectivity.MiShareService"
        const val miShareServiceDescriptor = "com.miui.mishare.IMiShareService"
        const val discoverCallbackDescriptor = "com.miui.mishare.IMiShareDiscoverCallback"
        const val transactionGetState = 1
        const val transactionDiscoverWithIntent = 7
        const val transactionStopDiscover = 8
        const val transactionOnDeviceUpdated = 1
        const val transactionOnDeviceLost = 2
        const val bindTimeoutMs = 3_000L
        const val defaultDiscoverTimeoutMs = 5_000L
        const val maxDiscoverTimeoutMs = 12_000L

        fun IBinder.getState(): Int {
            val data = Parcel.obtain()
            val reply = Parcel.obtain()
            return try {
                data.writeInterfaceToken(miShareServiceDescriptor)
                if (!transact(transactionGetState, data, reply, 0)) {
                    throw RemoteException("getState transact=false")
                }
                reply.readException()
                reply.readInt()
            } finally {
                reply.recycle()
                data.recycle()
            }
        }

        fun IBinder.discoverWithIntent(callback: IInterface, intent: Intent) {
            val data = Parcel.obtain()
            try {
                data.writeInterfaceToken(miShareServiceDescriptor)
                data.writeStrongBinder(callback.asBinder())
                data.writeTypedObjectCompat(intent, 0)
                if (!transact(transactionDiscoverWithIntent, data, null, IBinder.FLAG_ONEWAY)) {
                    throw RemoteException("discoverWithIntent transact=false")
                }
            } finally {
                data.recycle()
            }
        }

        fun IBinder.stopDiscover(callback: IInterface) {
            val data = Parcel.obtain()
            try {
                data.writeInterfaceToken(miShareServiceDescriptor)
                data.writeStrongBinder(callback.asBinder())
                transact(transactionStopDiscover, data, null, IBinder.FLAG_ONEWAY)
            } finally {
                data.recycle()
            }
        }

        fun Parcel.writeTypedObjectCompat(value: Parcelable?, flags: Int) {
            if (value == null) {
                writeInt(0)
            } else {
                writeInt(1)
                value.writeToParcel(this, flags)
            }
        }

        fun Parcel.readRemoteDevice(): MiShareRemoteDevice? {
            if (readInt() == 0) {
                return null
            }
            val deviceId = readString().orEmpty()
            val extras = readBundle(AndroidMiShareServiceClient::class.java.classLoader) ?: Bundle()
            val rawExtras = extras.keySet()
                .associateWith { key ->
                    runCatching { extras.get(key)?.toString().orEmpty() }.getOrDefault("")
                }
                .filterValues { it.isNotEmpty() }
            return MiShareRemoteDevice(
                deviceId = deviceId,
                displayName = rawExtras["nickname"] ?: rawExtras["device_name"] ?: rawExtras["name"],
                model = rawExtras["model"],
                manufacture = rawExtras["manufacture"],
                serviceId = rawExtras["service_id"],
                source = rawExtras["discover_source_v2"] ?: rawExtras["discover_source"],
                rawExtras = rawExtras
            )
        }

        fun String.forSingleLineLog(): String =
            replace('\n', ' ').replace('\r', ' ').take(160)
    }
}
