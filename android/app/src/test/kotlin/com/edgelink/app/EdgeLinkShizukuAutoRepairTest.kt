package com.edgelink.app

import com.edgelink.ui.EdgeLinkUiState
import org.junit.Assert.assertEquals
import org.junit.Test

class EdgeLinkShizukuAutoRepairTest {
    @Test
    fun repairsOnlyMissingAccess() {
        val state = EdgeLinkUiState(
            notificationSyncEnabled = true,
            notificationAccessGranted = false,
            notificationPostGranted = true,
            remoteInputAccessGranted = true,
            smsAccessGranted = true
        )

        assertEquals(
            listOf(
                ShizukuAutoRepairTarget.Notification
            ),
            shizukuAutoRepairTargets(state)
        )
    }

    @Test
    fun doesNotRepairNotificationsWhenSyncIsDisabled() {
        val state = EdgeLinkUiState(
            notificationSyncEnabled = false,
            notificationAccessGranted = false,
            notificationPostGranted = false,
            remoteInputAccessGranted = true,
            smsAccessGranted = true
        )

        assertEquals(emptyList<ShizukuAutoRepairTarget>(), shizukuAutoRepairTargets(state))
    }

    @Test
    fun doesNothingWhenEveryAccessIsReady() {
        val state = EdgeLinkUiState(
            notificationSyncEnabled = true,
            notificationAccessGranted = true,
            notificationPostGranted = true,
            remoteInputAccessGranted = true,
            smsAccessGranted = true
        )

        assertEquals(emptyList<ShizukuAutoRepairTarget>(), shizukuAutoRepairTargets(state))
    }

    @Test
    fun repairsMissingRemoteInputAndSms() {
        val state = EdgeLinkUiState(
            notificationSyncEnabled = true,
            notificationAccessGranted = true,
            notificationPostGranted = true,
            remoteInputAccessGranted = false,
            smsAccessGranted = false
        )

        assertEquals(
            listOf(
                ShizukuAutoRepairTarget.RemoteInput,
                ShizukuAutoRepairTarget.Sms
            ),
            shizukuAutoRepairTargets(state)
        )
    }
}
