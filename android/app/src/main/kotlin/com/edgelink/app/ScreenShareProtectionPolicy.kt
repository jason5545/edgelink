package com.edgelink.app

internal const val GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS =
    "disable_screen_share_protections_for_apps_and_notifications"
internal const val XIAOMI_SCREEN_PROJECT_PRIVATE_ON = "screen_project_private_on"

internal data class ScreenShareProtectionTarget(
    val globalDisableProtections: Int,
    val xiaomiPrivateProjection: Int
)

internal fun screenShareProtectionTarget(privacyEnabled: Boolean): ScreenShareProtectionTarget =
    if (privacyEnabled) {
        ScreenShareProtectionTarget(
            globalDisableProtections = 0,
            xiaomiPrivateProjection = 1
        )
    } else {
        ScreenShareProtectionTarget(
            globalDisableProtections = 1,
            xiaomiPrivateProjection = 0
        )
    }
