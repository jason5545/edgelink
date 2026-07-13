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

object AndroidMiLinkCastServiceBridge {
    private const val serviceAction = "com.milink.sdk.cast.v2.client.public"
    private const val servicePackage = "com.milink.service"
    private const val descriptor = "com.milink.sdk.cast.v2.IMiLinkCastServiceV2"
    private const val transactionIsAgreePrivacy = 27
    private const val transactionIsVerifyCodeInputShown = 30
    private const val transactionIsAuthDeviceConnecting = 32

    suspend fun probe(context: Context): ShizukuOperationResult =
        withContext(Dispatchers.IO) {
            val appContext = context.applicationContext
            val steps = mutableListOf<String>()
            val bound = runCatching {
                withTimeout(5_000) {
                    bind(appContext)
                }
            }.getOrElse { error ->
                val message = "MiLink cast service failed: bind=${error.javaClass.simpleName}:${error.message}"
                EdgeLinkLog.info("xiaomi.milink.cast_service_probe $message")
                return@withContext ShizukuOperationResult(success = false, message = message)
            }

            try {
                steps += "bind=ok"
                steps += "privacy=${bound.binder.transactBoolean(transactionIsAgreePrivacy)}"
                steps += "authConnecting=${bound.binder.transactBoolean(transactionIsAuthDeviceConnecting)}"
                steps += "verifyCodeShown=${bound.binder.transactBoolean(transactionIsVerifyCodeInputShown)}"
                val message = "MiLink cast service ok: ${steps.joinToString()}"
                EdgeLinkLog.info("xiaomi.milink.cast_service_probe $message")
                ShizukuOperationResult(success = true, message = message)
            } catch (error: Throwable) {
                steps += "error=${error.javaClass.simpleName}:${error.message}"
                val message = "MiLink cast service failed: ${steps.joinToString()}"
                EdgeLinkLog.info("xiaomi.milink.cast_service_probe $message")
                ShizukuOperationResult(success = false, message = message)
            } finally {
                runCatching { appContext.unbindService(bound.connection) }
            }
        }

    private suspend fun bind(context: Context): BoundMiLinkCastService =
        suspendCancellableCoroutine { continuation ->
            val intent = Intent(serviceAction).setPackage(servicePackage)
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, service: IBinder) {
                    if (continuation.isActive) {
                        continuation.resume(BoundMiLinkCastService(service, this))
                    }
                }

                override fun onServiceDisconnected(name: ComponentName) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(
                            IllegalStateException("MiLink cast service disconnected.")
                        )
                    }
                }

                override fun onNullBinding(name: ComponentName) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(
                            IllegalStateException("MiLink cast service returned null binding.")
                        )
                    }
                }
            }

            val bound = runCatching {
                context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            }.getOrElse { error ->
                continuation.resumeWithException(error)
                return@suspendCancellableCoroutine
            }
            if (!bound) {
                continuation.resumeWithException(
                    IllegalStateException("bindService returned false.")
                )
                return@suspendCancellableCoroutine
            }
            continuation.invokeOnCancellation {
                runCatching { context.unbindService(connection) }
            }
        }

    private fun IBinder.transactBoolean(code: Int): Boolean {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(descriptor)
            check(transact(code, data, reply, 0)) { "transact($code) returned false" }
            reply.readException()
            return reply.readInt() != 0
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    private data class BoundMiLinkCastService(
        val binder: IBinder,
        val connection: ServiceConnection
    )
}
