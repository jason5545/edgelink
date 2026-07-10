package com.edgelink.app

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Process
import android.provider.Settings
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

private const val SCREEN_SHARE_PROTECTION_PREFS = "edgelink_screen_share_protection"
private const val KEY_HAS_SNAPSHOT = "hasSnapshot"
private const val KEY_GLOBAL_WAS_PRESENT = "globalWasPresent"
private const val KEY_GLOBAL_VALUE = "globalValue"
private const val KEY_XIAOMI_WAS_PRESENT = "xiaomiWasPresent"
private const val KEY_XIAOMI_VALUE = "xiaomiValue"
private const val KEY_TARGET_GLOBAL = "targetGlobal"
private const val KEY_TARGET_XIAOMI = "targetXiaomi"
private const val SETTINGS_CALL_USER_KEY = "_user"
private const val SETTINGS_DELETE_GLOBAL = "DELETE_global"
private const val SETTINGS_DELETE_SECURE = "DELETE_secure"

class AndroidScreenShareProtectionGuard(context: Context) {
    private val appContext = context.applicationContext
    private val resolver = appContext.contentResolver
    private val prefs = appContext.getSharedPreferences(SCREEN_SHARE_PROTECTION_PREFS, Context.MODE_PRIVATE)
    private val mutex = Mutex()
    private var ownsSnapshot = false

    suspend fun prepare(privacyEnabled: Boolean, reason: String): Boolean = mutex.withLock {
        val requestedTarget = screenShareProtectionTarget(privacyEnabled)
        val existingSnapshot = loadSnapshot()
        if (existingSnapshot != null) {
            if (!ownsSnapshot || existingSnapshot.target != requestedTarget) {
                val restored = restoreLocked(
                    snapshot = existingSnapshot,
                    reason = if (ownsSnapshot) "${reason}_retarget" else "${reason}_stale"
                )
                if (!restored) {
                    return@withLock false
                }
            } else {
                val reapplied = applyTargetLocked(existingSnapshot, reason = "${reason}_reassert")
                if (!reapplied) {
                    restoreLocked(existingSnapshot, reason = "${reason}_reassert_failed")
                }
                return@withLock reapplied
            }
        }

        val snapshot = ProtectionSnapshot(
            originalGlobal = readGlobal(),
            originalXiaomi = readXiaomi(),
            target = requestedTarget
        )
        if (!saveSnapshot(snapshot)) {
            EdgeLinkLog.warn("screen.android.protection_snapshot_save_failed reason=$reason")
            return@withLock false
        }
        ownsSnapshot = true

        val applied = applyTargetLocked(snapshot, reason)
        if (!applied) {
            restoreLocked(snapshot, reason = "${reason}_apply_failed")
        }
        applied
    }

    suspend fun restore(reason: String): Boolean = mutex.withLock {
        val snapshot = loadSnapshot() ?: run {
            ownsSnapshot = false
            return@withLock true
        }
        restoreLocked(snapshot, reason)
    }

    private suspend fun applyTargetLocked(snapshot: ProtectionSnapshot, reason: String): Boolean {
        val globalTarget = snapshot.target.globalDisableProtections.toString()
        val xiaomiTarget = snapshot.target.xiaomiPrivateProjection.toString()

        // Keep these independent: one failed write must not prevent the other from being attempted.
        val globalApplied = writeGlobal(globalTarget)
        val xiaomiApplied = writeXiaomi(xiaomiTarget)
        val globalAfter = readGlobal()
        val xiaomiAfter = readXiaomi()
        val success = globalApplied && xiaomiApplied &&
            globalAfter == globalTarget && xiaomiAfter == xiaomiTarget

        if (success) {
            EdgeLinkLog.info(
                "screen.android.protection_applied reason=$reason privacy=${snapshot.target.globalDisableProtections == 0} global=$globalAfter xiaomi=$xiaomiAfter"
            )
        } else {
            EdgeLinkLog.warn(
                "screen.android.protection_apply_failed reason=$reason globalWrite=$globalApplied globalAfter=$globalAfter xiaomiWrite=$xiaomiApplied xiaomiAfter=$xiaomiAfter"
            )
        }
        return success
    }

    private suspend fun restoreLocked(snapshot: ProtectionSnapshot, reason: String): Boolean {
        val globalRestored = restoreSettingIfStillOwned(
            name = "global",
            current = ::readGlobal,
            write = ::writeGlobal,
            target = snapshot.target.globalDisableProtections.toString(),
            original = snapshot.originalGlobal
        )
        val xiaomiRestored = restoreSettingIfStillOwned(
            name = "xiaomi",
            current = ::readXiaomi,
            write = ::writeXiaomi,
            target = snapshot.target.xiaomiPrivateProjection.toString(),
            original = snapshot.originalXiaomi
        )
        val success = globalRestored && xiaomiRestored
        if (success) {
            val cleared = prefs.edit().clear().commit()
            if (cleared) {
                ownsSnapshot = false
                EdgeLinkLog.info("screen.android.protection_restored reason=$reason")
            } else {
                EdgeLinkLog.warn("screen.android.protection_snapshot_clear_failed reason=$reason")
                return false
            }
        } else {
            EdgeLinkLog.warn(
                "screen.android.protection_restore_failed reason=$reason global=$globalRestored xiaomi=$xiaomiRestored"
            )
        }
        return success
    }

    private suspend fun restoreSettingIfStillOwned(
        name: String,
        current: () -> String?,
        write: suspend (String?) -> Boolean,
        target: String,
        original: String?
    ): Boolean {
        val before = current()
        if (before != target) {
            EdgeLinkLog.info(
                "screen.android.protection_restore_skipped_external key=$name current=$before target=$target"
            )
            return true
        }
        val wrote = write(original)
        val after = current()
        return wrote && after == original
    }

    private fun readGlobal(): String? =
        Settings.Global.getString(resolver, GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS)

    private fun readXiaomi(): String? =
        Settings.Secure.getString(resolver, XIAOMI_SCREEN_PROJECT_PRIVATE_ON)

    private suspend fun writeGlobal(value: String?): Boolean =
        writeSetting(
            namespace = "global",
            key = GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS,
            value = value,
            uri = Settings.Global.CONTENT_URI,
            deleteMethod = SETTINGS_DELETE_GLOBAL,
            directWrite = { Settings.Global.putString(resolver, GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS, it) },
            readBack = ::readGlobal
        )

    private suspend fun writeXiaomi(value: String?): Boolean =
        writeSetting(
            namespace = "secure",
            key = XIAOMI_SCREEN_PROJECT_PRIVATE_ON,
            value = value,
            uri = Settings.Secure.CONTENT_URI,
            deleteMethod = SETTINGS_DELETE_SECURE,
            directWrite = { Settings.Secure.putString(resolver, XIAOMI_SCREEN_PROJECT_PRIVATE_ON, it) },
            readBack = ::readXiaomi
        )

    private suspend fun writeSetting(
        namespace: String,
        key: String,
        value: String?,
        uri: Uri,
        deleteMethod: String,
        directWrite: (String) -> Boolean,
        readBack: () -> String?
    ): Boolean {
        if (AndroidProtectedSettings.canWriteSecureSettingsDirectly(appContext)) {
            val directSuccess = runCatching {
                if (value == null) {
                    deleteDirect(uri, deleteMethod, key)
                } else {
                    directWrite(value)
                }
            }.getOrElse { error ->
                EdgeLinkLog.warn("screen.android.protection_direct_write_failed namespace=$namespace key=$key", error)
                false
            }
            if (directSuccess && readBack() == value) {
                return true
            }
        }

        if (!AndroidShizukuSupport.hasPermission()) {
            return false
        }
        val result = runCatching {
            AndroidShizukuSupport.writeScreenShareSetting(appContext, namespace, key, value)
        }.getOrElse { error ->
            ShizukuOperationResult(success = false, message = error.message.orEmpty())
        }
        if (!result.success) {
            EdgeLinkLog.warn(
                "screen.android.protection_shizuku_write_failed namespace=$namespace key=$key message=${result.message}"
            )
        }
        return result.success && readBack() == value
    }

    private fun deleteDirect(uri: Uri, method: String, key: String): Boolean {
        val extras = Bundle().apply {
            putInt(SETTINGS_CALL_USER_KEY, Process.myUid() / 100_000)
        }
        resolver.call(uri, method, key, extras)
        return true
    }

    private fun saveSnapshot(snapshot: ProtectionSnapshot): Boolean =
        prefs.edit()
            .clear()
            .putBoolean(KEY_HAS_SNAPSHOT, true)
            .putBoolean(KEY_GLOBAL_WAS_PRESENT, snapshot.originalGlobal != null)
            .putString(KEY_GLOBAL_VALUE, snapshot.originalGlobal)
            .putBoolean(KEY_XIAOMI_WAS_PRESENT, snapshot.originalXiaomi != null)
            .putString(KEY_XIAOMI_VALUE, snapshot.originalXiaomi)
            .putInt(KEY_TARGET_GLOBAL, snapshot.target.globalDisableProtections)
            .putInt(KEY_TARGET_XIAOMI, snapshot.target.xiaomiPrivateProjection)
            .commit()

    private fun loadSnapshot(): ProtectionSnapshot? {
        if (!prefs.getBoolean(KEY_HAS_SNAPSHOT, false)) {
            return null
        }
        return ProtectionSnapshot(
            originalGlobal = if (prefs.getBoolean(KEY_GLOBAL_WAS_PRESENT, false)) {
                prefs.getString(KEY_GLOBAL_VALUE, null)
            } else {
                null
            },
            originalXiaomi = if (prefs.getBoolean(KEY_XIAOMI_WAS_PRESENT, false)) {
                prefs.getString(KEY_XIAOMI_VALUE, null)
            } else {
                null
            },
            target = ScreenShareProtectionTarget(
                globalDisableProtections = prefs.getInt(KEY_TARGET_GLOBAL, 0),
                xiaomiPrivateProjection = prefs.getInt(KEY_TARGET_XIAOMI, 0)
            )
        )
    }

    private data class ProtectionSnapshot(
        val originalGlobal: String?,
        val originalXiaomi: String?,
        val target: ScreenShareProtectionTarget
    )

    companion object {
        fun canControl(context: Context): Boolean =
            AndroidProtectedSettings.canWriteSecureSettings(context.applicationContext)
    }
}
