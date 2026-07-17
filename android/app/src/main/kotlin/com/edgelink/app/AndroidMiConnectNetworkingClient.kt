package com.edgelink.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Parcel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class AndroidMiConnectNetworkingClient(
    context: Context
) {
    private val appContext = context.applicationContext

    suspend fun probe(request: MiConnectNetworkingProbeRequest): MiConnectNetworkingProbeResult =
        withContext(Dispatchers.IO) {
            val bound = withTimeout(bindTimeoutMs) {
                bind()
            }
            try {
                val binder = bound.binder
                val trustedDeviceIds = request.deviceIds
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                    .distinct()

                val local = binder.transactTrustedDevice(
                    label = "getLocalDeviceInfo",
                    transaction = transactionGetLocalDeviceInfo
                )
                val trustedList = binder.transactTrustedDeviceList(
                    label = "getTrustedDeviceList",
                    transaction = transactionGetTrustedDeviceList
                )
                val trustedInfos = trustedDeviceIds.associateWith { deviceId ->
                    binder.transactTrustedDevice(
                        label = "getTrustedDeviceInfo($deviceId)",
                        transaction = transactionGetTrustedDeviceInfo
                    ) { parcel -> parcel.writeString(deviceId) }
                }
                val serviceLists = trustedDeviceIds.associateWith { deviceId ->
                    binder.transactBusinessServiceList(
                        label = "getServiceInfoList($deviceId)",
                        transaction = transactionGetServiceInfoList
                    ) { parcel -> parcel.writeString(deviceId) }
                }
                val addService = if (request.addServiceInfo) {
                    binder.transactInt(
                        label = "addServiceInfo(${request.serviceName})",
                        transaction = transactionAddServiceInfo
                    ) { parcel ->
                        parcel.writeInt(1)
                        parcel.writeString(request.serviceName)
                        parcel.writeString(request.servicePackageName)
                        parcel.writeByteArray(request.serviceData)
                        parcel.writeString(edgeLinkPackage)
                    }
                } else {
                    null
                }

                MiConnectNetworkingProbeResult(
                    descriptor = binder.descriptorSummary(),
                    localDevice = local,
                    trustedDevices = trustedList,
                    trustedDeviceInfos = trustedInfos,
                    serviceInfoLists = serviceLists,
                    addServiceInfo = addService,
                    requestedServiceName = request.serviceName,
                    requestedServicePackageName = request.servicePackageName,
                    serviceDataHex = request.serviceData.toHexString()
                )
            } finally {
                runCatching { appContext.unbindService(bound.connection) }
            }
        }

    private suspend fun bind(): BoundMiConnectNetworkingService =
        suspendCancellableCoroutine { continuation ->
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, service: IBinder) {
                    if (continuation.isActive) {
                        continuation.resume(BoundMiConnectNetworkingService(service, this))
                    }
                }

                override fun onServiceDisconnected(name: ComponentName) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(
                            IllegalStateException("service disconnected ${name.flattenToShortString()}")
                        )
                    }
                }

                override fun onNullBinding(name: ComponentName) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(
                            IllegalStateException("service returned null ${name.flattenToShortString()}")
                        )
                    }
                }
            }

            val intent = Intent(networkingServiceAction)
                .setClassName(miConnectPackage, networkingServiceClass)
            val bound = runCatching {
                appContext.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            }.getOrElse { error ->
                continuation.resumeWithException(error)
                return@suspendCancellableCoroutine
            }
            if (!bound) {
                continuation.resumeWithException(IllegalStateException("bindService returned false"))
                return@suspendCancellableCoroutine
            }
            continuation.invokeOnCancellation {
                runCatching { appContext.unbindService(connection) }
            }
        }

    private fun IBinder.transactTrustedDevice(
        label: String,
        transaction: Int,
        writeArgs: (Parcel) -> Unit = {}
    ): MiConnectBinderCall<MiConnectTrustedDeviceSnapshot?> =
        transactValue(label, transaction, writeArgs) { reply ->
            reply.readTypedTrustedDevice()
        }

    private fun IBinder.transactTrustedDeviceList(
        label: String,
        transaction: Int,
        writeArgs: (Parcel) -> Unit = {}
    ): MiConnectBinderCall<List<MiConnectTrustedDeviceSnapshot>> =
        transactValue(label, transaction, writeArgs) { reply ->
            reply.readTypedTrustedDeviceList().orEmpty()
        }

    private fun IBinder.transactBusinessServiceList(
        label: String,
        transaction: Int,
        writeArgs: (Parcel) -> Unit = {}
    ): MiConnectBinderCall<List<MiConnectBusinessServiceSnapshot>> =
        transactValue(label, transaction, writeArgs) { reply ->
            reply.readTypedBusinessServiceList().orEmpty()
        }

    private fun IBinder.transactInt(
        label: String,
        transaction: Int,
        writeArgs: (Parcel) -> Unit = {}
    ): MiConnectBinderCall<Int> =
        transactValue(label, transaction, writeArgs) { reply ->
            reply.readInt()
        }

    private fun <T> IBinder.transactValue(
        label: String,
        transaction: Int,
        writeArgs: (Parcel) -> Unit,
        readReply: (Parcel) -> T
    ): MiConnectBinderCall<T> {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(networkingDescriptor)
            writeArgs(data)
            val accepted = transact(transaction, data, reply, 0)
            if (!accepted) {
                MiConnectBinderCall(label = label, error = "transact($transaction) returned false")
            } else {
                reply.readException()
                MiConnectBinderCall(label = label, value = readReply(reply))
            }
        } catch (error: Throwable) {
            MiConnectBinderCall(
                label = label,
                error = "${error.javaClass.simpleName}:${error.message.orEmpty()}"
            )
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    private fun Parcel.readTypedTrustedDevice(): MiConnectTrustedDeviceSnapshot? {
        if (readInt() == 0) {
            return null
        }
        return MiConnectTrustedDeviceSnapshot(
            deviceId = readString().orEmpty(),
            deviceType = readInt(),
            deviceName = readString().orEmpty(),
            mediumTypes = readInt(),
            trustedTypes = readInt()
        )
    }

    private fun Parcel.readTypedTrustedDeviceList(): List<MiConnectTrustedDeviceSnapshot>? {
        val size = readInt()
        if (size < 0) {
            return null
        }
        return buildList {
            repeat(size.coerceAtMost(maxListItemsToParse)) {
                readTypedTrustedDevice()?.let(::add)
            }
        }
    }

    private fun Parcel.readTypedBusinessService(): MiConnectBusinessServiceSnapshot? {
        if (readInt() == 0) {
            return null
        }
        return MiConnectBusinessServiceSnapshot(
            serviceName = readString().orEmpty(),
            packageName = readString().orEmpty(),
            serviceData = createByteArray() ?: ByteArray(0)
        )
    }

    private fun Parcel.readTypedBusinessServiceList(): List<MiConnectBusinessServiceSnapshot>? {
        val size = readInt()
        if (size < 0) {
            return null
        }
        return buildList {
            repeat(size.coerceAtMost(maxListItemsToParse)) {
                readTypedBusinessService()?.let(::add)
            }
        }
    }

    private fun IBinder.descriptorSummary(): String =
        runCatching { interfaceDescriptor.orEmpty() }
            .getOrElse { error -> "${error.javaClass.simpleName}:${error.message.orEmpty()}" }

    private data class BoundMiConnectNetworkingService(
        val binder: IBinder,
        val connection: ServiceConnection
    )

    private companion object {
        const val edgeLinkPackage = "com.edgelink.app"
        const val miConnectPackage = "com.xiaomi.mi_connect_service"
        const val networkingServiceClass = "com.xiaomi.continuity.networking.service.NetworkingService"
        const val networkingServiceAction = "com.xiaomi.continuity.networking.service.NetworkingService"
        const val networkingDescriptor = "com.xiaomi.continuity.networking.INetworkingManager"
        const val transactionGetTrustedDeviceInfo = 3
        const val transactionGetLocalDeviceInfo = 4
        const val transactionGetTrustedDeviceList = 5
        const val transactionAddServiceInfo = 7
        const val transactionGetServiceInfoList = 9
        const val bindTimeoutMs = 3_000L
        const val maxListItemsToParse = 64
    }
}

internal data class MiConnectNetworkingProbeRequest(
    val deviceIds: List<String>,
    val addServiceInfo: Boolean = false,
    val serviceName: String = "miLyraShare",
    val servicePackageName: String = "com.edgelink.app",
    val serviceData: ByteArray = AndroidMiConnectNetworkingDefaults.defaultLyraShareServiceData()
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as MiConnectNetworkingProbeRequest

        if (deviceIds != other.deviceIds) return false
        if (addServiceInfo != other.addServiceInfo) return false
        if (serviceName != other.serviceName) return false
        if (servicePackageName != other.servicePackageName) return false
        return serviceData.contentEquals(other.serviceData)
    }

    override fun hashCode(): Int {
        var result = deviceIds.hashCode()
        result = 31 * result + addServiceInfo.hashCode()
        result = 31 * result + serviceName.hashCode()
        result = 31 * result + servicePackageName.hashCode()
        result = 31 * result + serviceData.contentHashCode()
        return result
    }
}

internal data class MiConnectNetworkingProbeResult(
    val descriptor: String,
    val localDevice: MiConnectBinderCall<MiConnectTrustedDeviceSnapshot?>,
    val trustedDevices: MiConnectBinderCall<List<MiConnectTrustedDeviceSnapshot>>,
    val trustedDeviceInfos: Map<String, MiConnectBinderCall<MiConnectTrustedDeviceSnapshot?>>,
    val serviceInfoLists: Map<String, MiConnectBinderCall<List<MiConnectBusinessServiceSnapshot>>>,
    val addServiceInfo: MiConnectBinderCall<Int>?,
    val requestedServiceName: String,
    val requestedServicePackageName: String,
    val serviceDataHex: String
) {
    val hasPermissionError: Boolean
        get() = allCalls.any { call -> call.error?.contains("permission", ignoreCase = true) == true }

    val hasAnySuccessfulMetadataRead: Boolean
        get() = listOf(localDevice, trustedDevices).any { it.ok } ||
            trustedDeviceInfos.values.any { it.ok } ||
            serviceInfoLists.values.any { it.ok }

    fun message(addRequested: Boolean): String {
        val trustedCount = trustedDevices.value?.size
        val addText = addServiceInfo?.let { call ->
            if (call.ok) " addCode=${call.value}" else " addError=${call.error}"
        }.orEmpty()
        return "MiConnect networking descriptor=$descriptor local=${localDevice.shortText()} " +
            "trusted=${trustedCount?.toString() ?: trustedDevices.shortText()}" +
            if (addRequested) " service=$requestedServiceName package=$requestedServicePackageName data=$serviceDataHex$addText" else ""
    }

    fun toCommandData(): Map<String, String> {
        val data = linkedMapOf<String, String>()
        data["descriptor"] = descriptor
        data["local"] = localDevice.value?.compactSummary() ?: localDevice.shortText()
        data["trustedCount"] = trustedDevices.value?.size?.toString() ?: ""
        data["trustedSample"] = trustedDevices.value
            ?.take(6)
            ?.joinToString("|") { it.compactSummary() }
            .orEmpty()
        trustedDevices.error?.let { data["trustedError"] = it }
        localDevice.error?.let { data["localError"] = it }
        trustedDeviceInfos.forEach { (deviceId, call) ->
            data["device.$deviceId"] = call.value?.compactSummary() ?: call.shortText()
        }
        serviceInfoLists.forEach { (deviceId, call) ->
            val services = call.value
            val serviceMatches = services
                ?.filter { it.serviceName == requestedServiceName }
                .orEmpty()
            val packageMatches = serviceMatches
                .filter { it.packageName == requestedServicePackageName }
            data["service.$deviceId.count"] = services?.size?.toString().orEmpty()
            data["service.$deviceId.sample"] = services
                ?.take(12)
                ?.joinToString("|") { it.compactSummary() }
                .orEmpty()
            data["service.$deviceId.matchCount"] = serviceMatches.size.toString()
            data["service.$deviceId.matches"] = serviceMatches
                .take(12)
                .joinToString("|") { it.compactSummary() }
            data["service.$deviceId.packageMatchCount"] = packageMatches.size.toString()
            data["service.$deviceId.packageMatches"] = packageMatches
                .take(12)
                .joinToString("|") { it.compactSummary() }
            call.error?.let { data["service.$deviceId.error"] = it }
        }
        addServiceInfo?.let { call ->
            data["addService.code"] = call.value?.toString().orEmpty()
            data["addService.error"] = call.error.orEmpty()
            data["addService.serviceName"] = requestedServiceName
            data["addService.packageName"] = requestedServicePackageName
            data["addService.dataHex"] = serviceDataHex
        }
        data["permissionError"] = hasPermissionError.toString()
        return data
    }

    private val allCalls: List<MiConnectBinderCall<*>>
        get() = buildList {
            add(localDevice)
            add(trustedDevices)
            addAll(trustedDeviceInfos.values)
            addAll(serviceInfoLists.values)
            addServiceInfo?.let(::add)
        }
}

internal data class MiConnectBinderCall<T>(
    val label: String,
    val value: T? = null,
    val error: String? = null
) {
    val ok: Boolean
        get() = error == null

    fun shortText(): String =
        if (ok) {
            value?.toString() ?: "null"
        } else {
            "error=$error"
        }
}

internal data class MiConnectTrustedDeviceSnapshot(
    val deviceId: String,
    val deviceType: Int,
    val deviceName: String,
    val mediumTypes: Int,
    val trustedTypes: Int
) {
    fun compactSummary(): String =
        "id=$deviceId type=$deviceType medium=$mediumTypes trusted=$trustedTypes name=$deviceName"
}

internal data class MiConnectBusinessServiceSnapshot(
    val serviceName: String,
    val packageName: String,
    val serviceData: ByteArray
) {
    fun compactSummary(): String =
        "service=$serviceName package=$packageName data=${serviceData.toHexString()}"

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as MiConnectBusinessServiceSnapshot

        if (serviceName != other.serviceName) return false
        if (packageName != other.packageName) return false
        return serviceData.contentEquals(other.serviceData)
    }

    override fun hashCode(): Int {
        var result = serviceName.hashCode()
        result = 31 * result + packageName.hashCode()
        result = 31 * result + serviceData.contentHashCode()
        return result
    }
}

internal object AndroidMiConnectNetworkingDefaults {
    data class ServiceProfile(
        val serviceName: String,
        val serviceData: ByteArray
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (javaClass != other?.javaClass) return false

            other as ServiceProfile

            if (serviceName != other.serviceName) return false
            return serviceData.contentEquals(other.serviceData)
        }

        override fun hashCode(): Int {
            var result = serviceName.hashCode()
            result = 31 * result + serviceData.contentHashCode()
            return result
        }
    }

    fun defaultLyraShareServiceData(): ByteArray =
        byteArrayOf(
            0x00,
            0x00,
            0x00,
            0x00,
            0x12,
            0x00,
            0x00,
            0x01,
            0x03
        )

    fun defaultMirrorServiceData(): ByteArray =
        byteArrayOf(0x0C, 0xDD.toByte(), 0xFF.toByte(), 0xFC.toByte())

    fun serviceProfile(raw: String?): ServiceProfile? =
        when (raw?.trim()?.lowercase()) {
            "lyra", "lyrashare", "milyrashare", "share" ->
                ServiceProfile("miLyraShare", defaultLyraShareServiceData())
            "mirror", "mirrorcast", "cast" ->
                ServiceProfile("cast", defaultMirrorServiceData())
            "mirrorsynergy", "synergy" ->
                ServiceProfile("synergy", defaultMirrorServiceData())
            else -> null
        }

    fun parseHex(raw: String?): ByteArray? {
        val text = raw
            ?.trim()
            ?.removePrefix("0x")
            ?.replace(" ", "")
            ?.replace(":", "")
            ?.replace("-", "")
            ?: return null
        if (text.isEmpty() || text.length % 2 != 0 || text.any { !it.isDigit() && it.lowercaseChar() !in 'a'..'f' }) {
            return null
        }
        return ByteArray(text.length / 2) { index ->
            text.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }
}

private fun ByteArray.toHexString(): String =
    joinToString(separator = "") { byte -> "%02X".format(byte.toInt() and 0xff) }
