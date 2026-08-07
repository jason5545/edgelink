package com.edgelink.app

// Exact root commands the app may run through the Shizuku service. The
// command policy (EdgeLinkShizukuCommandPolicy) matches these constants
// verbatim, so callers must use the shared arrays instead of rebuilding the
// command inline.
object EdgeLinkShizukuCommands {
    private const val MILINK_SERVICE_PACKAGE = "com.milink.service"

    // Re-register the call-relay route after a reboot: replay the
    // com.milink.service BOOT_COMPLETED receiver when the process is dead and
    // pin it against the battery saver so TeleService's continuity callbacks
    // repopulate the relay device list.
    val RELAY_ROUTE_REGISTER_COMMAND = arrayOf(
        "sh",
        "-c",
        "if [ -z \"\$(pidof $MILINK_SERVICE_PACKAGE)\" ]; then " +
            "am broadcast -a android.intent.action.BOOT_COMPLETED " +
            "-n $MILINK_SERVICE_PACKAGE/com.xiaomi.dist.xntc.core.XntcBootReceiver; " +
            "dumpsys deviceidle whitelist +$MILINK_SERVICE_PACKAGE; " +
            "cmd appops set $MILINK_SERVICE_PACKAGE RUN_IN_BACKGROUND allow; " +
            "cmd appops set $MILINK_SERVICE_PACKAGE RUN_ANY_IN_BACKGROUND allow; " +
            "fi; exit 0"
    )
}
