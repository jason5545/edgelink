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
    fun hooksInCallUiMainProcessForRelayUiState() {
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHook(
                packageName = "com.android.incallui",
                processName = "com.android.incallui"
            )
        )
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHookInCallUi(
                packageName = "com.android.incallui",
                processName = "com.android.incallui"
            )
        )

        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHookInCallUi(
                packageName = "com.android.incallui",
                processName = "com.android.incallui:remote"
            )
        )
        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHookInCallUi(
                packageName = "com.android.phone",
                processName = "com.android.phone"
            )
        )
    }

    @Test
    fun hooksAndroidPhoneMainProcessForRelayDeviceState() {
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHook(
                packageName = "com.android.phone",
                processName = "com.android.phone"
            )
        )
        assertTrue(
            MiLinkPrivilegeHookPolicy.shouldHookAndroidPhone(
                packageName = "com.android.phone",
                processName = "com.android.phone"
            )
        )

        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHookAndroidPhone(
                packageName = "com.android.phone",
                processName = "com.android.phone:remote"
            )
        )
        assertFalse(
            MiLinkPrivilegeHookPolicy.shouldHookAndroidPhone(
                packageName = "com.android.incallui",
                processName = "com.android.incallui"
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
    fun parsesMirrorFakeRemoteAttachFlag() {
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAttachEnabled("1"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAttachEnabled("true"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAttachEnabled("attach"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAttachEnabled("ON"))

        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAttachEnabled("0"))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAttachEnabled("false"))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAttachEnabled(""))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAttachEnabled(null))
    }

    @Test
    fun parsesMirrorFakeRemoteKeyProbeFlag() {
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteKeyEnabled("1"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteKeyEnabled("true"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteKeyEnabled("key"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteKeyEnabled("PROBE"))

        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteKeyEnabled("0"))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteKeyEnabled("false"))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteKeyEnabled(""))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteKeyEnabled(null))
    }

    @Test
    fun parsesMirrorFakeRemoteUsingPadFlag() {
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteUsingPadEnabled("1"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteUsingPadEnabled("true"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteUsingPadEnabled("pad"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteUsingPadEnabled("USING_PAD"))

        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteUsingPadEnabled("0"))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteUsingPadEnabled("false"))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteUsingPadEnabled(""))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteUsingPadEnabled(null))
    }

    @Test
    fun parsesMirrorFakeRemoteCallState() {
        assertEquals(0, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteCallState("idle"))
        assertEquals(1, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteCallState("ringing"))
        assertEquals(2, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteCallState("offhook"))
        assertEquals(2, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteCallState("OFF_HOOK"))
        assertEquals(2, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteCallState("2"))

        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteCallState("true"))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteCallState(""))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteCallState(null))
    }

    @Test
    fun parsesMirrorFakeRemoteAudioAllowFlag() {
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioAllowed("1"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioAllowed("true"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioAllowed("allow"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioAllowed("AUDIO"))

        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioAllowed("0"))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioAllowed("false"))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioAllowed(""))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioAllowed(null))
    }

    @Test
    fun parsesMirrorFakeRemoteAudioParamsProbeFlag() {
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioParamsEnabled("1"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioParamsEnabled("true"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioParamsEnabled("params"))
        assertTrue(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioParamsEnabled("PROBE"))

        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioParamsEnabled("0"))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioParamsEnabled("false"))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioParamsEnabled(""))
        assertFalse(MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioParamsEnabled(null))
    }

    @Test
    fun parsesMirrorFakeRemoteAudioStartMode() {
        assertEquals("source", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode("1"))
        assertEquals("source", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode("true"))
        assertEquals("source", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode("source"))
        assertEquals("source", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode("START_SOURCE"))
        assertEquals("sink", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode("sink"))
        assertEquals("sink", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode("audio_sink"))
        assertEquals("both", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode("both"))
        assertEquals("both", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode("source+sink"))

        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode("0"))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode("false"))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode(""))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioStartMode(null))
    }

    @Test
    fun parsesMirrorFakeRemoteAudioSinkArg() {
        assertEquals(1, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioSinkArg(" 1 "))
        assertEquals(7102, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioSinkArg("7102"))
        assertEquals(65535, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioSinkArg("65535"))

        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioSinkArg("0"))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioSinkArg("65536"))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioSinkArg("abc"))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteAudioSinkArg(null))
    }

    @Test
    fun parsesMirrorFakeRemoteEndpointHost() {
        assertEquals("10.0.0.42", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointHost(" 10.0.0.42 "))
        assertEquals("fd00::1234", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointHost("fd00::1234"))
        assertEquals("mac.local", MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointHost("mac.local"))

        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointHost(""))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointHost("10.0.0.42 extra"))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointHost(null))
    }

    @Test
    fun parsesMirrorFakeRemoteEndpointPort() {
        assertEquals(1, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointPort("1"))
        assertEquals(7102, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointPort(" 7102 "))
        assertEquals(65535, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointPort("65535"))

        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointPort("0"))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointPort("65536"))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointPort("abc"))
        assertEquals(null, MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointPort(null))
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
