package com.edgelink.app

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

// Root re-registration of the call-relay route. After a phone reboot MIUI
// blocks com.milink.service from starting, and TeleService's relay path goes
// blind: PhoneContinuityController.isContinuityServiceConnected() is just
// "mRelayFilteredServiceInfoMap.size() > 0", and that map is only filled by
// the continuity networking callbacks (onServiceOnline/...) fed from
// com.milink.service, which also broadcasts
// com.milink.service.connectivity.CONNECTION_SERVICE_CHANGED_ON to re-trigger
// TeleService init. Observed live after reboot: milink.service dead,
// "Filtered device size 0", "maybeRelayCall no - relay not connected", so
// call audio never reaches the Mac. Fix: on every call start, go through the
// project's Shizuku service (the only sanctioned root channel) and, if
// com.milink.service is not running, replay its BOOT_COMPLETED receiver and
// pin it against the battery saver so discovery re-registers the Mac's
// relayCall service.
object RelayRouteRegistrar {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val registerCommand = EdgeLinkShizukuCommands.RELAY_ROUTE_REGISTER_COMMAND

    fun ensureRegistered(context: Context) {
        val appContext = context.applicationContext
        scope.launch {
            val result = AndroidShizukuSupport.runShellCommand(appContext, registerCommand)
            if (result == null) {
                EdgeLinkLog.warn("phone.android.relay_route_register_shizuku_unavailable")
            } else {
                EdgeLinkLog.info(
                    "phone.android.relay_route_register exit=${result.exitCode}"
                )
            }
        }
    }
}
