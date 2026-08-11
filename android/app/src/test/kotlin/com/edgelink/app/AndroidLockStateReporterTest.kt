package com.edgelink.app

import com.edgelink.core.PhoneLockStateBody
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [AndroidLockStateReporter]'s push mechanics, including the
 * 2026-08-11 HyperOS SCREEN_ON regression: KeyguardManager.isDeviceLocked
 * flipped to false ~300ms after every SCREEN_ON while the swipe-up
 * lockscreen was still on screen, the 15s heartbeat kept re-pushing that
 * "unlocked" lie, and the Mac's freshness gate then streamed the phone's
 * lock screen with no unlock prompt. The reporter now samples
 * isKeyguardLocked (lockscreen showing), which stays true in that state;
 * these tests pin the emission behaviour around that sampler.
 */
class AndroidLockStateReporterTest {

    private fun makeReporter(
        sampler: () -> Boolean?
    ): Pair<AndroidLockStateReporter, CopyOnWriteArrayList<PhoneLockStateBody>> {
        val pushes = CopyOnWriteArrayList<PhoneLockStateBody>()
        val reporter = AndroidLockStateReporter(context = null) { body -> pushes += body }
        reporter.log = { }
        reporter.lockStateSampler = sampler
        return reporter to pushes
    }

    // The fixed SCREEN_ON sequence: the device is locked, the screen turns
    // on, and the keyguard is still showing — every sample must report
    // locked=true, so the Mac never sees a fresh "unlocked" lie.
    @Test
    fun screenOnWithKeyguardShowingKeepsReportingLocked() = runBlocking {
        var keyguardShowing = true
        val (reporter, pushes) = makeReporter { keyguardShowing }
        reporter.heartbeatMs = 50
        reporter.start()
        try {
            // session_connected-style forced push, then the SCREEN_ON sample
            // (keyguard still showing), then a couple of heartbeats.
            reporter.sendCurrent("session_connected")
            reporter.sendCurrent("screen_on")
            kotlinx.coroutines.delay(180)
            assertTrue(pushes.isNotEmpty())
            assertTrue(
                "no push may claim unlocked while the keyguard shows: $pushes",
                pushes.all { it.locked }
            )
        } finally {
            reporter.stop()
        }
    }

    @Test
    fun unlockTransitionPushesUnlockedOnce() = runBlocking {
        var keyguardShowing = true
        val (reporter, pushes) = makeReporter { keyguardShowing }
        reporter.heartbeatMs = 10_000 // keep the heartbeat out of this test
        reporter.start()
        try {
            reporter.sendCurrent("session_connected")
            keyguardShowing = false
            reporter.sendCurrent("user_present")
            // start() and session_connected are both forced pushes, then the
            // unlock transition flips the state.
            assertEquals(listOf(true, true, false), pushes.map { it.locked })
        } finally {
            reporter.stop()
        }
    }

    // The Mac freshness-gates "unlocked" reports, so the heartbeat must
    // re-push even when the state has not changed (force = true).
    @Test
    fun heartbeatRePushesUnchangedState() = runBlocking {
        val (reporter, pushes) = makeReporter { true }
        reporter.heartbeatMs = 50
        reporter.start()
        try {
            kotlinx.coroutines.delay(180)
            assertTrue(
                "heartbeat must re-push unchanged state, got ${pushes.size} pushes",
                pushes.size >= 3
            )
            assertTrue(pushes.all { it.locked })
        } finally {
            reporter.stop()
        }
    }

    @Test
    fun nullSampleEmitsNothing() = runBlocking {
        val (reporter, pushes) = makeReporter { null }
        reporter.heartbeatMs = 50
        reporter.start()
        try {
            reporter.sendCurrent("session_connected")
            kotlinx.coroutines.delay(120)
            assertTrue(pushes.isEmpty())
        } finally {
            reporter.stop()
        }
    }
}
