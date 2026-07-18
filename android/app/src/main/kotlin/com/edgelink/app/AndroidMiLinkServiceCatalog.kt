package com.edgelink.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import com.edgelink.core.MiLinkServiceCapabilityBody
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume

object AndroidMiLinkServiceCatalog {
    private const val miSharePackage = "com.miui.mishare.connectivity"
    private const val mirrorPackage = "com.xiaomi.mirror"
    private const val audioMonitorPackage = "com.miui.audiomonitor"
    private const val continuityStaticConfigAction = "com.xiaomi.continuity.action.STATIC_CONFIG_ACTION"
    private const val mirrorSynergyAction = "com.xiaomi.mirror.ACTION_SYNERGY_SERVICE"
    private const val distAudioAction = "com.miui.audiomonitor.action.DistAudioService"

    suspend fun probe(
        context: Context,
        messengerTransportOk: Boolean,
        castServiceOk: Boolean,
        mirrorRemoteDeviceCount: Int = 0
    ): ServiceCatalogResult =
        withContext(Dispatchers.IO) {
            val appContext = context.applicationContext
            val pm = appContext.packageManager

            val miShareInstalled = pm.isPackageInstalled(miSharePackage)
            val mirrorInstalled = pm.isPackageInstalled(mirrorPackage)
            val audioInstalled = pm.isPackageInstalled(audioMonitorPackage)
            val miShareStaticConfig = pm.hasService(
                Intent(continuityStaticConfigAction).setPackage(miSharePackage)
            )
            val mirrorSynergyService = pm.hasService(
                Intent(mirrorSynergyAction)
                    .setPackage(mirrorPackage)
                    .addCategory(Intent.CATEGORY_DEFAULT)
            )
            val distAudioService = pm.hasService(
                Intent(distAudioAction).setPackage(audioMonitorPackage)
            )
            val synergyBind = if (mirrorSynergyService) {
                bindProbe(
                    appContext,
                    Intent(mirrorSynergyAction)
                        .setPackage(mirrorPackage)
                        .addCategory(Intent.CATEGORY_DEFAULT)
                )
            } else {
                BindProbeResult(false, "service=missing")
            }
            val distAudioBind = if (distAudioService) {
                bindProbe(appContext, Intent(distAudioAction).setPackage(audioMonitorPackage))
            } else {
                BindProbeResult(false, "service=missing")
            }

            val xiaomiFamilyDevice = isXiaomiOrPocoDevice()
            val miShareAvailable = miShareInstalled && miShareStaticConfig && messengerTransportOk
            val miSharePreferred = false
            val mirrorRemoteAvailable = mirrorRemoteDeviceCount > 0
            val mirrorScreenAvailable = mirrorInstalled && castServiceOk
            val mirrorScreenPreferred = xiaomiFamilyDevice && mirrorScreenAvailable
            val recentAppsAvailable = mirrorInstalled && castServiceOk && mirrorRemoteAvailable
            val synergyAvailable = mirrorInstalled && mirrorSynergyService && synergyBind.success && mirrorRemoteAvailable
            val distAudioAvailable = audioInstalled && distAudioService && distAudioBind.success
            val officialXiaomiPreferred = false

            val services = listOf(
                MiLinkServiceCapabilityBody(
                    id = "xiaomi.mishare.miLyraShare",
                    packageName = miSharePackage,
                    appName = miSharePackage,
                    serviceName = "miLyraShare",
                    category = "fileTransfer",
                    route = "xiaomi.lyra",
                    available = miShareAvailable,
                    preferred = miSharePreferred,
                    evidence = "package=${miShareInstalled.step()} staticConfig=${miShareStaticConfig.step()} messenger=${messengerTransportOk.step()} macEndpoint=mdnsOnly"
                ),
                MiLinkServiceCapabilityBody(
                    id = "xiaomi.mishare.miLyraShareTransfer",
                    packageName = miSharePackage,
                    appName = miSharePackage,
                    serviceName = "miLyraShareTransfer",
                    category = "fileTransfer",
                    route = "xiaomi.lyra",
                    available = miShareAvailable,
                    preferred = miSharePreferred,
                    evidence = "package=${miShareInstalled.step()} staticConfig=${miShareStaticConfig.step()} messenger=${messengerTransportOk.step()} macEndpoint=mdnsOnly transferChannel=pending"
                ),
                MiLinkServiceCapabilityBody(
                    id = "xiaomi.mirror.cast",
                    packageName = mirrorPackage,
                    appName = mirrorPackage,
                    serviceName = "cast",
                    category = "screen",
                    route = "xiaomi.mirror",
                    available = mirrorScreenAvailable,
                    preferred = mirrorScreenPreferred,
                    evidence = "package=${mirrorInstalled.step()} castBinder=${castServiceOk.step()} remoteDevices=$mirrorRemoteDeviceCount remoteArm=realDevice xiaomiFamily=${xiaomiFamilyDevice.step()} defaultRoute=xiaomiMirror"
                ),
                MiLinkServiceCapabilityBody(
                    id = "xiaomi.mirror.synergy",
                    packageName = mirrorPackage,
                    appName = mirrorPackage,
                    serviceName = "synergy",
                    category = "screen",
                    route = "xiaomi.mirror",
                    available = synergyAvailable,
                    preferred = officialXiaomiPreferred,
                    bindAction = mirrorSynergyAction,
                    evidence = "package=${mirrorInstalled.step()} service=${mirrorSynergyService.step()} bind=${synergyBind.message} remoteDevices=$mirrorRemoteDeviceCount diagnosticOnly=true"
                ),
                MiLinkServiceCapabilityBody(
                    id = "xiaomi.mirror.RecentApps",
                    packageName = mirrorPackage,
                    appName = mirrorPackage,
                    serviceName = "RecentApps",
                    category = "recentApps",
                    route = "xiaomi.mirror",
                    available = recentAppsAvailable,
                    preferred = officialXiaomiPreferred,
                    evidence = "package=${mirrorInstalled.step()} castBinder=${castServiceOk.step()} remoteDevices=$mirrorRemoteDeviceCount serverChannel=mirror-owned diagnosticOnly=true"
                ),
                MiLinkServiceCapabilityBody(
                    id = "xiaomi.audiomonitor.DistAudioService",
                    packageName = audioMonitorPackage,
                    appName = "com.miui.audiomonitor",
                    serviceName = "DistAudioService",
                    category = "audio",
                    route = "xiaomi.distAudio",
                    available = distAudioAvailable,
                    preferred = officialXiaomiPreferred,
                    bindAction = distAudioAction,
                    evidence = "package=${audioInstalled.step()} service=${distAudioService.step()} bind=${distAudioBind.message} diagnosticOnly=true"
                )
            )

            val preferredRoutes = mapOf(
                "fileTransfer" to services.preferredRoute("fileTransfer", "edgelink.fileTransfer"),
                "screen" to services.preferredRoute("screen", "edgelink.screen"),
                "recentApps" to services.preferredRoute("recentApps", "edgelink.generic"),
                "audio" to services.preferredRoute("audio", "edgelink.webrtcAudio")
            )
            EdgeLinkLog.info(
                "xiaomi.milink.service_catalog " +
                    services.joinToString(separator = " ") { service ->
                        "${service.id}=${service.available.step()}"
                    } +
                    " xiaomiFamily=${xiaomiFamilyDevice.step()} preferred=$preferredRoutes"
            )
            ServiceCatalogResult(
                services = services,
                preferredRoutes = preferredRoutes
            )
        }

    private fun isXiaomiOrPocoDevice(): Boolean {
        val fields = listOf(
            Build.MANUFACTURER,
            Build.BRAND,
            Build.PRODUCT,
            Build.DEVICE,
            Build.MODEL
        )
        return fields.any { raw ->
            val value = raw.lowercase(Locale.US)
            value.contains("xiaomi") || value.contains("poco") || value.contains("redmi")
        }
    }

    private suspend fun bindProbe(context: Context, intent: Intent): BindProbeResult =
        runCatching {
            withTimeout(2_500) {
                suspendCancellableCoroutine { continuation ->
                    fun ServiceConnection.finish(result: BindProbeResult) {
                        if (continuation.isActive) {
                            continuation.resume(result)
                            runCatching { context.unbindService(this) }
                        }
                    }

                    val connection = object : ServiceConnection {
                        override fun onServiceConnected(name: ComponentName, service: IBinder) {
                            finish(BindProbeResult(true, "ok:${name.flattenToShortString()}"))
                        }

                        override fun onServiceDisconnected(name: ComponentName) {
                            finish(BindProbeResult(false, "disconnected:${name.flattenToShortString()}"))
                        }

                        override fun onNullBinding(name: ComponentName) {
                            finish(BindProbeResult(false, "null:${name.flattenToShortString()}"))
                        }
                    }

                    val bound = runCatching {
                        context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
                    }.getOrElse { error ->
                        continuation.resume(
                            BindProbeResult(false, "${error.javaClass.simpleName}:${error.message}")
                        )
                        return@suspendCancellableCoroutine
                    }
                    if (!bound) {
                        continuation.resume(BindProbeResult(false, "bind=false"))
                        return@suspendCancellableCoroutine
                    }
                    continuation.invokeOnCancellation {
                        runCatching { context.unbindService(connection) }
                    }
                }
            }
        }.getOrElse { error ->
            BindProbeResult(false, "${error.javaClass.simpleName}:${error.message}")
        }

    private fun PackageManager.isPackageInstalled(packageName: String): Boolean =
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                getPackageInfo(packageName, 0)
            }
            true
        }.getOrDefault(false)

    private fun PackageManager.hasService(intent: Intent): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            queryIntentServices(intent, PackageManager.ResolveInfoFlags.of(0)).isNotEmpty()
        } else {
            @Suppress("DEPRECATION")
            queryIntentServices(intent, 0).isNotEmpty()
        }

    private fun Boolean.step(): String =
        if (this) "ok" else "missing"

    private fun List<MiLinkServiceCapabilityBody>.preferredRoute(
        category: String,
        fallback: String
    ): String =
        firstOrNull { it.category == category && it.available && it.preferred }?.id ?: fallback

    data class ServiceCatalogResult(
        val services: List<MiLinkServiceCapabilityBody>,
        val preferredRoutes: Map<String, String>
    )

    private data class BindProbeResult(
        val success: Boolean,
        val message: String
    )
}
