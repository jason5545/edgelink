package com.edgelink.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MiLinkPrivilegeHookPolicyTest {
    @Test
    fun hooksOnlyMiLinkRuntimeProcess() {
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHook(
                packageName = "com.milink.service",
                processName = "com.milink.runtime"
            )
        )

        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHook(
                packageName = "com.milink.service",
                processName = "com.milink.service:audio"
            )
        )
        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHook(
                packageName = "com.edgelink.app",
                processName = "com.edgelink.app"
            )
        )
    }

    @Test
    fun hooksMiLinkMainProcessForCastService() {
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHook(
                packageName = "com.milink.service",
                processName = "com.milink.service"
            )
        )
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHookMainService(
                packageName = "com.milink.service",
                processName = "com.milink.service"
            )
        )

        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHookMainService(
                packageName = "com.milink.service",
                processName = "com.milink.runtime"
            )
        )
    }

    @Test
    fun hooksXiaomiMirrorMainProcessForPhoneContinuity() {
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHook(
                packageName = "com.xiaomi.mirror",
                processName = "com.xiaomi.mirror"
            )
        )
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHookXiaomiMirror(
                packageName = "com.xiaomi.mirror",
                processName = "com.xiaomi.mirror"
            )
        )

        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHookXiaomiMirror(
                packageName = "com.xiaomi.mirror",
                processName = "com.xiaomi.mirror:remote"
            )
        )
        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHookXiaomiMirror(
                packageName = "com.milink.service",
                processName = "com.milink.service"
            )
        )
    }

    @Test
    fun hooksMiConnectMainProcessForNetworkingMetadata() {
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHook(
                packageName = "com.xiaomi.mi_connect_service",
                processName = "com.xiaomi.mi_connect_service"
            )
        )
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHookMiConnectService(
                packageName = "com.xiaomi.mi_connect_service",
                processName = "com.xiaomi.mi_connect_service"
            )
        )

        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHookMiConnectService(
                packageName = "com.xiaomi.mi_connect_service",
                processName = "com.xiaomi.mi_connect_service:remote"
            )
        )
        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHookMiConnectService(
                packageName = "com.xiaomi.mirror",
                processName = "com.xiaomi.mirror"
            )
        )
    }

    @Test
    fun noLongerHooksAudioMonitor() {
        // The call-uplink inject moved entirely into the root Shizuku
        // service (CallUplinkInjector); the in-process LSPosed feed inside
        // audiomonitor and its fallback were removed, so the module must
        // not load into com.miui.audiomonitor anymore.
        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHook(
                packageName = "com.miui.audiomonitor",
                processName = "com.miui.audiomonitor"
            )
        )
    }

    @Test
    fun allowsOnlyKnownMirrorPhoneProviderMethods() {
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("getCallRelayService"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("queryRemoteDevices"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("openRemoteDeviceMirror"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("openRemoteDeviceMirrorByBtMac"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("performMirrorDeviceIconClick"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("startRemoteMainMirrorDisplay"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("showRelayData"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("syncRelayData"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("cancelRelayData"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("startMediaRelay"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("stopMediaRelay"))

        assertFalse(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("sendRemoteBroadcast"))
        assertFalse(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("stopShare"))
        assertFalse(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod(null))
    }

    @Test
    fun allowsOnlyEdgeLinkCallerPackage() {
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedCallerPackage("com.edgelink.app"))
        assertTrue(MiLinkPrivilegeHookPolicy.hasAllowedCallerPackage(arrayOf("com.edgelink.app")))
        assertTrue(
            MiLinkPrivilegeHookPolicy.isAllowedMiConnectCallerPackage(
                requestedPackageName = "com.edgelink.app",
                callerPackages = arrayOf("com.edgelink.app")
            )
        )
        assertTrue(
            MiLinkPrivilegeHookPolicy.isAllowedMiConnectCallerPackage(
                requestedPackageName = null,
                callerPackages = arrayOf("com.edgelink.app")
            )
        )

        assertFalse(MiLinkPrivilegeHookPolicy.isAllowedCallerPackage("com.android.shell"))
        assertFalse(MiLinkPrivilegeHookPolicy.isAllowedCallerPackage("com.milink.service"))
        assertFalse(MiLinkPrivilegeHookPolicy.hasAllowedCallerPackage(arrayOf("com.android.shell")))
        assertFalse(MiLinkPrivilegeHookPolicy.hasAllowedCallerPackage(null))
        assertFalse(
            MiLinkPrivilegeHookPolicy.isAllowedMiConnectCallerPackage(
                requestedPackageName = "com.android.shell",
                callerPackages = arrayOf("com.edgelink.app")
            )
        )
        assertFalse(
            MiLinkPrivilegeHookPolicy.isAllowedMiConnectCallerPackage(
                requestedPackageName = "com.edgelink.app",
                callerPackages = arrayOf("com.android.shell")
            )
        )
    }

    @Test
    fun hooksMiShareConnectivityPackage() {
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHook(
                packageName = "com.miui.mishare.connectivity",
                processName = "com.miui.mishare.connectivity"
            )
        )
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHookMiShare(
                packageName = "com.miui.mishare.connectivity",
                processName = "com.miui.mishare.connectivity"
            )
        )
        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHookMiShare(
                packageName = "com.miui.mishare",
                processName = "com.miui.mishare"
            )
        )
    }

    @Test
    fun keyboardAndPointerProviderStackIsGoneButGlobalStays() {
        // Mirror keyboard and pointer moved to the official cast-channel
        // route, so the hook-side provider must not answer them anymore.
        // Global (back/home/recents/power) still injects via the hook.
        assertFalse(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("edgeLinkKeyboard"))
        assertFalse(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("edgeLinkPointer"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("edgeLinkGlobal"))
    }
}
