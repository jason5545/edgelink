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
            screenDimmingAccessGranted = false,
            smsAccessGranted = true
        )

        assertEquals(
            listOf(
                ShizukuAutoRepairTarget.Notification,
                ShizukuAutoRepairTarget.Screen
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
            screenDimmingAccessGranted = true,
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
            screenDimmingAccessGranted = true,
            smsAccessGranted = true
        )

        assertEquals(emptyList<ShizukuAutoRepairTarget>(), shizukuAutoRepairTargets(state))
    }
}
