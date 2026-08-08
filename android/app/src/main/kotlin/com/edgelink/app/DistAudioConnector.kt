package com.edgelink.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.media.AudioAttributes
import android.media.AudioFormat
import android.os.IBinder
import android.os.Parcel

// Drives the phone-side DistAudio connect for relayed calls by binding the
// audiomonitor system service (com.miui.audiomonitor.distaudio.IDistAudioService)
// directly — the same AIDL TeleService/InCallUI would use, gated only by the
// normal-level ACCESS_DIST_AUDIO_SERVICE permission. TeleService's own
// trigger is inert on CN ROM (isConnectDiscAudio() requires an international
// build) and InCallUI's RelayEventListener registration lapses, so outgoing
// relayed calls never get their DistAudio route connected otherwise.
object DistAudioConnector {
    private const val DESCRIPTOR = "com.miui.audiomonitor.distaudio.IDistAudioService"
    private const val DEVICE_INFO_CLASS = "com.miui.audiomonitor.distaudio.data.DistAudioDeviceInfo"
    private const val ACTION = "com.miui.audiomonitor.action.DistAudioService"
    private const val PKG = "com.miui.audiomonitor"

    private const val TRANSACTION_CONNECT = 1
    private const val TRANSACTION_DISCONNECT = 2
    private const val TRANSACTION_GET_DEVICES = 3

    private const val SIMPLE_FLAG = 2304

    @Volatile
    var appContext: Context? = null

    private var binder: IBinder? = null
    private var bound = false
    private var connectingDeviceId: String? = null
    private var connectedRoute: ConnectedRoute? = null

    private data class ConnectedRoute(val deviceId: String, val deviceName: String, val deviceType: Int)

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            binder = service
            EdgeLinkLog.info("phone.android.distaudio.service_connected")
            val target = connectingDeviceId
            if (target != null) {
                connectLocked(target)
            }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            EdgeLinkLog.info("phone.android.distaudio.service_disconnected")
            binder = null
            bound = false
            connectedRoute = null
        }
    }

    @Synchronized
    fun onRelayedCallActive(context: Context, deviceId: String) {
        // No-hook uplink inject first: it is independent of the DistAudio
        // connect below and can start feeding the modem uplink immediately.
        CallUplinkInject.start(context)
        if (connectedRoute?.deviceId == deviceId) return
        connectingDeviceId = deviceId
        if (binder != null) {
            connectLocked(deviceId)
            return
        }
        if (bound) return
        val intent = Intent(ACTION).setPackage(PKG)
        bound = runCatching {
            context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        }.onFailure { error ->
            EdgeLinkLog.warn("phone.android.distaudio.bind_failed", error)
        }.getOrDefault(false)
        EdgeLinkLog.info("phone.android.distaudio.bind_result=$bound device=$deviceId")
        if (!bound) {
            connectingDeviceId = null
        }
    }

    @Synchronized
    fun onCallEnded(deviceId: String?) {
        connectingDeviceId = null
        CallUplinkInject.stop()
        val route = connectedRoute ?: return
        if (deviceId != null && route.deviceId != deviceId) return
        disconnectLocked(route)
        connectedRoute = null
        appContext?.let { context ->
            runCatching { context.unbindService(connection) }
        }
        binder = null
        bound = false
    }

    private fun connectLocked(deviceId: String) {
        val service = binder ?: return
        val devices = queryDevices(service)
        EdgeLinkLog.info("phone.android.distaudio.devices=${devices.map { it.first }}")
        val device = devices.firstOrNull { it.first.equals(deviceId, ignoreCase = true) }
        if (device == null) {
            EdgeLinkLog.info("phone.android.distaudio.device_not_found device=$deviceId")
            return
        }
        val ok = runCatching {
            transactRoute(service, TRANSACTION_CONNECT, device)
        }.onFailure { error ->
            EdgeLinkLog.warn("phone.android.distaudio.connect_failed", error)
        }.getOrDefault(false)
        EdgeLinkLog.info("phone.android.distaudio.connect_result=$ok device=$deviceId")
        if (ok) {
            connectedRoute = ConnectedRoute(device.first, device.second, device.third)
        }
    }

    private fun disconnectLocked(route: ConnectedRoute) {
        val service = binder ?: return
        runCatching {
            transactRoute(service, TRANSACTION_DISCONNECT, Triple(route.deviceId, route.deviceName, route.deviceType))
        }.onFailure { error ->
            EdgeLinkLog.warn("phone.android.distaudio.disconnect_failed", error)
        }
        EdgeLinkLog.info("phone.android.distaudio.disconnected device=${route.deviceId}")
    }

    private fun queryDevices(service: IBinder): List<Triple<String, String, Int>> {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(DESCRIPTOR)
            service.transact(TRANSACTION_GET_DEVICES, data, reply, 0)
            reply.readException()
            val count = reply.readInt()
            if (count <= 0) {
                return emptyList()
            }
            (0 until count).mapNotNull {
                if (reply.readInt() == 0) {
                    null
                } else {
                    Triple(reply.readString().orEmpty(), reply.readString().orEmpty(), reply.readInt())
                }
            }
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    // DistAudioRoute parcel: writeParcelable(deviceInfo) then the three
    // framework parcelables — the AIDL presence marker is written by callers.
    private fun transactRoute(service: IBinder, code: Int, device: Triple<String, String, Int>): Boolean {
        val attributes = AudioAttributes.Builder()
            .setFlags(SIMPLE_FLAG)
            .setUsage(1)
            .setContentType(2)
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(2)
            .setSampleRate(8000)
            .setChannelMask(12)
            .build()
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(DESCRIPTOR)
            data.writeInt(1)
            data.writeString(DEVICE_INFO_CLASS)
            data.writeString(device.first)
            data.writeString(device.second)
            data.writeInt(device.third)
            data.writeParcelable(attributes, 0)
            data.writeParcelable(format, 0)
            data.writeParcelable(format, 0)
            service.transact(code, data, reply, 0)
            reply.readException()
            true
        } finally {
            data.recycle()
            reply.recycle()
        }
    }
}
