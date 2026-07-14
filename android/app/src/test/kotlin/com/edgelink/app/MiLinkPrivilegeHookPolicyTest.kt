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
    fun allowsOnlyKnownMirrorPhoneProviderMethods() {
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("getCallRelayService"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("queryRemoteDevices"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("startMediaRelay"))
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("stopMediaRelay"))

        assertFalse(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("openRemoteDeviceMirror"))
        assertFalse(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod("sendRemoteBroadcast"))
        assertFalse(MiLinkPrivilegeHookPolicy.isAllowedMirrorPhoneProviderMethod(null))
    }

    @Test
    fun allowsOnlyEdgeLinkCallerPackage() {
        assertTrue(MiLinkPrivilegeHookPolicy.isAllowedCallerPackage("com.edgelink.app"))
        assertTrue(MiLinkPrivilegeHookPolicy.hasAllowedCallerPackage(arrayOf("com.edgelink.app")))

        assertFalse(MiLinkPrivilegeHookPolicy.isAllowedCallerPackage("com.android.shell"))
        assertFalse(MiLinkPrivilegeHookPolicy.isAllowedCallerPackage("com.milink.service"))
        assertFalse(MiLinkPrivilegeHookPolicy.hasAllowedCallerPackage(arrayOf("com.android.shell")))
        assertFalse(MiLinkPrivilegeHookPolicy.hasAllowedCallerPackage(null))
    }

    @Test
    fun parsesMirrorFakeRemoteMode() {
        assertEquals("pad", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteMode("pad"))
        assertEquals("pad", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteMode("AndroidPad"))
        assertEquals("car", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteMode("androidpadcar"))

        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteMode(""))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteMode("phone"))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteMode(null))
    }

    @Test
    fun filtersFakeMirrorRemoteByQuery() {
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldIncludeFakeMirrorRemote(
                mode = "pad",
                manufacturer = null,
                platform = null
            )
        )
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldIncludeFakeMirrorRemote(
                mode = "pad",
                manufacturer = "xiaomi",
                platform = "AndroidPad"
            )
        )
        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldIncludeFakeMirrorRemote(
                mode = "pad",
                manufacturer = "other",
                platform = "AndroidPad"
            )
        )
        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldIncludeFakeMirrorRemote(
                mode = "pad",
                manufacturer = "xiaomi",
                platform = "AndroidPadCar"
            )
        )
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldIncludeFakeMirrorRemote(
                mode = "car",
                manufacturer = "xiaomi",
                platform = "AndroidPadCar"
            )
        )
    }
}
