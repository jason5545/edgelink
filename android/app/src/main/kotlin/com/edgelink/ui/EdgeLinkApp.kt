package com.edgelink.ui

import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.edgelink.core.InputKeyBody
import com.edgelink.core.InputPointerBody
import com.edgelink.core.InputTextBody

@Composable
fun EdgeLinkApp(
    state: EdgeLinkUiState = EdgeLinkUiState(),
    actions: EdgeLinkActions = EdgeLinkActions.Noop
) {
    EdgeLinkTheme {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background
        ) {
            DeviceControlScreen(state = state, actions = actions)
        }
    }
}

@Composable
private fun EdgeLinkTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val dark = isSystemInDarkTheme()
    val colorScheme = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && dark -> dynamicDarkColorScheme(context).amoled()
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> dynamicLightColorScheme(context)
        dark -> edgeLinkAmoledDarkScheme()
        else -> edgeLinkLightScheme()
    }

    MaterialTheme(
        colorScheme = colorScheme,
        content = content
    )
}

private fun ColorScheme.amoled(): ColorScheme =
    copy(
        background = Color.Black,
        onBackground = Color(0xFFECECEC),
        surface = Color.Black,
        onSurface = Color(0xFFECECEC),
        surfaceVariant = Color(0xFF202124),
        onSurfaceVariant = Color(0xFFD7D7D7),
        surfaceContainerLowest = Color.Black,
        surfaceContainerLow = Color(0xFF070707),
        surfaceContainer = Color(0xFF0D0D0D),
        surfaceContainerHigh = Color(0xFF151515),
        surfaceContainerHighest = Color(0xFF1E1E1E)
    )

private fun edgeLinkLightScheme(): ColorScheme =
    lightColorScheme(
        primary = Color(0xFF285EA8),
        onPrimary = Color.White,
        primaryContainer = Color(0xFFD6E3FF),
        onPrimaryContainer = Color(0xFF001B3F),
        tertiary = Color(0xFF51643F),
        onTertiary = Color.White,
        tertiaryContainer = Color(0xFFD4EABB),
        onTertiaryContainer = Color(0xFF102004),
        error = Color(0xFFBA1A1A),
        errorContainer = Color(0xFFFFDAD6),
        onErrorContainer = Color(0xFF410002),
        background = Color(0xFFFBFCFF),
        surface = Color(0xFFFBFCFF),
        surfaceVariant = Color(0xFFE0E2EC),
        outlineVariant = Color(0xFFC3C6D0)
    )

private fun edgeLinkAmoledDarkScheme(): ColorScheme =
    darkColorScheme(
        primary = Color(0xFFA8C7FA),
        onPrimary = Color(0xFF00315F),
        primaryContainer = Color(0xFF004786),
        onPrimaryContainer = Color(0xFFD6E3FF),
        tertiary = Color(0xFFB8CEA0),
        onTertiary = Color(0xFF243514),
        tertiaryContainer = Color(0xFF3A4C29),
        onTertiaryContainer = Color(0xFFD4EABB),
        error = Color(0xFFFFB4AB),
        onError = Color(0xFF690005),
        errorContainer = Color(0xFF93000A),
        onErrorContainer = Color(0xFFFFDAD6),
        background = Color.Black,
        onBackground = Color(0xFFECECEC),
        surface = Color.Black,
        onSurface = Color(0xFFECECEC),
        surfaceVariant = Color(0xFF202124),
        onSurfaceVariant = Color(0xFFD7D7D7),
        outlineVariant = Color(0xFF44474F),
        surfaceContainerLowest = Color.Black,
        surfaceContainerLow = Color(0xFF070707),
        surfaceContainer = Color(0xFF0D0D0D),
        surfaceContainerHigh = Color(0xFF151515),
        surfaceContainerHighest = Color(0xFF1E1E1E)
    )

enum class ConnectionPhase {
    Idle,
    Connecting,
    Handshaking,
    Connected,
    Reconnecting,
    Disconnected
}

data class EdgeLinkUiState(
    val localDeviceId: String = "",
    val peerName: String = "尚未配對 Mac",
    val peerDeviceId: String = "",
    val connectionStatus: String = "Starting",
    val connectionPhase: ConnectionPhase = ConnectionPhase.Idle,
    val isConnected: Boolean = false,
    val pairingHostIdInput: String = "",
    val pairingSas: String = "",
    val pairingPeerName: String = "",
    val isPairing: Boolean = false,
    val canConfirmPairing: Boolean = false,
    val autoReconnectEnabled: Boolean = true,
    val notificationSyncEnabled: Boolean = true,
    val screenSharePrivacyEnabled: Boolean = false,
    val screenSharePrivacyControlAvailable: Boolean = false,
    val remoteInputAccessGranted: Boolean = false,
    val notificationAccessGranted: Boolean = false,
    val notificationPostGranted: Boolean = true,
    val screenDimmingAccessGranted: Boolean = false,
    val smsAccessGranted: Boolean = false,
    val shizukuAvailable: Boolean = false,
    val shizukuSupported: Boolean = false,
    val shizukuPermissionGranted: Boolean = false,
    val shizukuPermissionRequestBlocked: Boolean = false,
    val shizukuUid: Int? = null
)

interface EdgeLinkActions {
    fun onPointer(body: InputPointerBody)
    fun onKey(body: InputKeyBody)
    fun onText(body: InputTextBody)
    fun onPairDigit(digit: String)
    fun onPairBackspace()
    fun onStartPairing()
    fun onConfirmPairing()
    fun onReconnect()
    fun onDisconnect()
    fun onQuit()
    fun onAutoReconnectChange(enabled: Boolean)
    fun onNotificationSyncChange(enabled: Boolean)
    fun onScreenSharePrivacyChange(enabled: Boolean)
    fun onOpenNotificationSettings()
    fun onOpenRemoteInputSettings()
    fun onOpenScreenDimmingSettings()
    fun onOpenSmsSettings()
    fun onRequestShizukuPermission()

    object Noop : EdgeLinkActions {
        override fun onPointer(body: InputPointerBody) = Unit
        override fun onKey(body: InputKeyBody) = Unit
        override fun onText(body: InputTextBody) = Unit
        override fun onPairDigit(digit: String) = Unit
        override fun onPairBackspace() = Unit
        override fun onStartPairing() = Unit
        override fun onConfirmPairing() = Unit
        override fun onReconnect() = Unit
        override fun onDisconnect() = Unit
        override fun onQuit() = Unit
        override fun onAutoReconnectChange(enabled: Boolean) = Unit
        override fun onNotificationSyncChange(enabled: Boolean) = Unit
        override fun onScreenSharePrivacyChange(enabled: Boolean) = Unit
        override fun onOpenNotificationSettings() = Unit
        override fun onOpenRemoteInputSettings() = Unit
        override fun onOpenScreenDimmingSettings() = Unit
        override fun onOpenSmsSettings() = Unit
        override fun onRequestShizukuPermission() = Unit
    }
}

private enum class EdgeLinkScreen {
    Dashboard,
    RemoteControl,
    Settings
}

@Composable
fun DeviceControlScreen(state: EdgeLinkUiState, actions: EdgeLinkActions) {
    var screenName by rememberSaveable { mutableStateOf(EdgeLinkScreen.Dashboard.name) }
    val currentScreen = remember(screenName) { EdgeLinkScreen.valueOf(screenName) }

    BackHandler(enabled = state.peerDeviceId.isNotEmpty() && currentScreen != EdgeLinkScreen.Dashboard) {
        screenName = EdgeLinkScreen.Dashboard.name
    }

    if (state.peerDeviceId.isEmpty()) {
        PairingScreen(state = state, actions = actions)
        return
    }

    when (currentScreen) {
        EdgeLinkScreen.Dashboard -> DashboardScreen(
            state = state,
            actions = actions,
            onOpenRemoteControl = { screenName = EdgeLinkScreen.RemoteControl.name },
            onOpenSettings = { screenName = EdgeLinkScreen.Settings.name }
        )
        EdgeLinkScreen.RemoteControl -> RemoteControlScreen(
            state = state,
            actions = actions,
            onBack = { screenName = EdgeLinkScreen.Dashboard.name }
        )
        EdgeLinkScreen.Settings -> SettingsScreen(
            state = state,
            actions = actions,
            onBack = { screenName = EdgeLinkScreen.Dashboard.name }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DashboardScreen(
    state: EdgeLinkUiState,
    actions: EdgeLinkActions,
    onOpenRemoteControl: () -> Unit,
    onOpenSettings: () -> Unit
) {
    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("EdgeLink") },
                actions = {
                    IconButton(onClick = onOpenSettings) {
                        Text("⚙", style = MaterialTheme.typography.titleLarge)
                    }
                }
            )
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item { ConnectionStatusCard(state = state, actions = actions) }
            item { PermissionHealthCard(state = state, actions = actions) }
            item { RemoteControlEntry(onOpenRemoteControl = onOpenRemoteControl) }
        }
    }
}

@Composable
private fun ConnectionStatusCard(state: EdgeLinkUiState, actions: EdgeLinkActions) {
    val colors = MaterialTheme.colorScheme
    val containerColor = when (state.connectionPhase) {
        ConnectionPhase.Connected -> colors.primaryContainer
        ConnectionPhase.Connecting,
        ConnectionPhase.Handshaking,
        ConnectionPhase.Reconnecting -> colors.tertiaryContainer
        ConnectionPhase.Disconnected -> colors.errorContainer
        ConnectionPhase.Idle -> colors.surfaceContainerHigh
    }
    val contentColor = when (state.connectionPhase) {
        ConnectionPhase.Connected -> colors.onPrimaryContainer
        ConnectionPhase.Connecting,
        ConnectionPhase.Handshaking,
        ConnectionPhase.Reconnecting -> colors.onTertiaryContainer
        ConnectionPhase.Disconnected -> colors.onErrorContainer
        ConnectionPhase.Idle -> colors.onSurface
    }

    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(
            containerColor = containerColor,
            contentColor = contentColor
        )
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(12.dp)
                        .background(contentColor, CircleShape)
                )
                Spacer(modifier = Modifier.width(10.dp))
                Text(
                    text = localizedStatus(state.connectionStatus),
                    style = MaterialTheme.typography.labelLarge
                )
            }

            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = state.peerName,
                    style = MaterialTheme.typography.headlineSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    text = state.peerDeviceId,
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }

            if (state.connectionPhase == ConnectionPhase.Connected) {
                OutlinedButton(
                    onClick = actions::onReconnect,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("重新連線")
                }
            } else {
                Button(
                    onClick = actions::onReconnect,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("重新連線")
                }
            }
        }
    }
}

@Composable
private fun PermissionHealthCard(state: EdgeLinkUiState, actions: EdgeLinkActions) {
    val missing = missingPermissions(state = state, actions = actions)
    if (missing.isEmpty()) {
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(24.dp),
            color = MaterialTheme.colorScheme.surfaceContainerLow
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .background(MaterialTheme.colorScheme.primary, CircleShape)
                )
                Spacer(modifier = Modifier.width(10.dp))
                Text(
                    text = "權限已就緒",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        return
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer,
            contentColor = MaterialTheme.colorScheme.onErrorContainer
        )
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text("需要補齊權限", style = MaterialTheme.typography.titleMedium)
            missing.forEach { permission ->
                MissingPermissionRow(permission = permission)
            }
        }
    }
}

@Composable
private fun MissingPermissionRow(permission: MissingPermission) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(permission.title, style = MaterialTheme.typography.labelLarge)
            Text(permission.detail, style = MaterialTheme.typography.bodySmall)
        }
        FilledTonalButton(onClick = permission.onOpen) {
            Text(permission.actionLabel)
        }
    }
}

@Composable
private fun RemoteControlEntry(onOpenRemoteControl: () -> Unit) {
    FilledTonalButton(
        onClick = onOpenRemoteControl,
        modifier = Modifier
            .fillMaxWidth()
            .height(64.dp)
    ) {
        Text("遠端控制")
    }
}

@Composable
private fun RemoteControlScreen(
    state: EdgeLinkUiState,
    actions: EdgeLinkActions,
    onBack: () -> Unit
) {
    var text by rememberSaveable { mutableStateOf("") }
    var keyboardExpanded by rememberSaveable { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        if (state.isConnected) {
            Touchpad(
                modifier = Modifier.fillMaxSize(),
                onPointer = actions::onPointer
            )
            RemoteBackButton(onBack = onBack)

            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                FilledTonalButton(
                    onClick = { keyboardExpanded = !keyboardExpanded },
                    modifier = Modifier.padding(16.dp)
                ) {
                    Text(if (keyboardExpanded) "收合鍵盤" else "開啟鍵盤")
                }

                AnimatedVisibility(
                    visible = keyboardExpanded,
                    enter = slideInVertically(initialOffsetY = { it }) + fadeIn(),
                    exit = slideOutVertically(targetOffsetY = { it }) + fadeOut()
                ) {
                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
                        tonalElevation = 6.dp,
                        shadowElevation = 6.dp,
                        color = MaterialTheme.colorScheme.surfaceContainerHigh
                    ) {
                        KeyboardPanel(
                            text = text,
                            onTextChange = { value -> text = value },
                            onSendText = {
                                if (text.isNotBlank()) {
                                    actions.onText(InputTextBody(text))
                                    text = ""
                                }
                            },
                            onKey = actions::onKey
                        )
                    }
                }
            }
        } else {
            RemoteBackButton(onBack = onBack)
            Column(
                modifier = Modifier
                    .align(Alignment.Center)
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Text("目前未連線", style = MaterialTheme.typography.headlineSmall)
                Text(
                    text = localizedStatus(state.connectionStatus),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Button(onClick = actions::onReconnect) {
                    Text("重新連線")
                }
            }
        }
    }
}

@Composable
private fun RemoteBackButton(onBack: () -> Unit) {
    Surface(
        modifier = Modifier
            .padding(14.dp)
            .size(48.dp),
        shape = CircleShape,
        tonalElevation = 4.dp,
        color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.92f)
    ) {
        IconButton(onClick = onBack) {
            Text("‹", fontSize = 30.sp)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsScreen(
    state: EdgeLinkUiState,
    actions: EdgeLinkActions,
    onBack: () -> Unit
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("設定") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Text("‹", fontSize = 30.sp)
                    }
                }
            )
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item {
                SettingsSection(title = "裝置資訊") {
                    MonoTextRow(label = "本機 ID", value = state.localDeviceId.ifEmpty { "尚未註冊" })
                    MonoTextRow(label = "Peer ID", value = state.peerDeviceId.ifEmpty { "尚未配對" })
                }
            }

            item {
                SettingsSection(title = "Shizuku") {
                    ShizukuStatusRow(state = state, actions = actions)
                }
            }

            item {
                SettingsSection(title = "同步") {
                    SettingsToggleRow(
                        label = "自動重新連線",
                        checked = state.autoReconnectEnabled,
                        onCheckedChange = actions::onAutoReconnectChange
                    )
                    HorizontalDivider()
                    NotificationToggleRow(
                        enabled = state.notificationSyncEnabled,
                        accessGranted = state.notificationAccessGranted,
                        postGranted = state.notificationPostGranted,
                        actionLabel = permissionActionLabel(state),
                        onCheckedChange = actions::onNotificationSyncChange,
                        onOpenSettings = actions::onOpenNotificationSettings
                    )
                }
            }

            item {
                SettingsSection(title = "螢幕投放") {
                    SettingsToggleRow(
                        label = "投放隱私保護",
                        supportingText = if (state.screenSharePrivacyEnabled) {
                            "隱藏投放中的通知與私密內容"
                        } else {
                            "投放時顯示通知與私密內容"
                        },
                        checked = state.screenSharePrivacyEnabled,
                        enabled = state.screenSharePrivacyControlAvailable,
                        onCheckedChange = actions::onScreenSharePrivacyChange
                    )
                    if (!state.screenSharePrivacyControlAvailable) {
                        Text(
                            text = "需要 WRITE_SECURE_SETTINGS 或 Shizuku 授權",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                        )
                    }
                }
            }

            item {
                SettingsSection(title = "權限明細") {
                    PermissionStatusRow(
                        label = "遠端輸入",
                        granted = state.remoteInputAccessGranted,
                        missingText = "需要啟用輔助使用服務",
                        actionLabel = permissionActionLabel(state),
                        onOpenSettings = actions::onOpenRemoteInputSettings
                    )
                    PermissionStatusRow(
                        label = "螢幕保持喚醒",
                        granted = state.screenDimmingAccessGranted,
                        missingText = "需要修改系統設定或顯示在其他應用程式上層",
                        actionLabel = permissionActionLabel(state),
                        onOpenSettings = actions::onOpenScreenDimmingSettings
                    )
                    PermissionStatusRow(
                        label = "SMS",
                        granted = state.smsAccessGranted,
                        missingText = "需要簡訊權限",
                        actionLabel = permissionActionLabel(state),
                        onOpenSettings = actions::onOpenSmsSettings
                    )
                }
            }

            item {
                FilledTonalButton(
                    onClick = actions::onDisconnect,
                    enabled = state.canDisconnect,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("中斷連線")
                }
            }

            item {
                Button(
                    onClick = actions::onQuit,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error,
                        contentColor = MaterialTheme.colorScheme.onError
                    ),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("結束 EdgeLink")
                }
            }
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow
    ) {
        Column(
            modifier = Modifier.padding(vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
            )
            content()
        }
    }
}

@Composable
private fun MonoTextRow(label: String, value: String) {
    ListItem(
        headlineContent = { Text(label) },
        supportingContent = {
            Text(
                text = value,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent)
    )
}

@Composable
private fun ShizukuStatusRow(state: EdgeLinkUiState, actions: EdgeLinkActions) {
    ListItem(
        headlineContent = { Text("狀態") },
        supportingContent = { Text(shizukuStatusText(state)) },
        trailingContent = {
            if (state.shizukuAvailable && state.shizukuSupported && !state.shizukuPermissionGranted && !state.shizukuPermissionRequestBlocked) {
                FilledTonalButton(onClick = actions::onRequestShizukuPermission) {
                    Text("授權")
                }
            }
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent)
    )
}

@Composable
private fun SettingsToggleRow(
    label: String,
    checked: Boolean,
    supportingText: String? = null,
    enabled: Boolean = true,
    onCheckedChange: (Boolean) -> Unit
) {
    ListItem(
        headlineContent = { Text(label) },
        supportingContent = supportingText?.let { text ->
            { Text(text) }
        },
        trailingContent = {
            Switch(
                checked = checked,
                enabled = enabled,
                onCheckedChange = onCheckedChange
            )
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent)
    )
}

@Composable
private fun NotificationToggleRow(
    enabled: Boolean,
    accessGranted: Boolean,
    postGranted: Boolean,
    actionLabel: String,
    onCheckedChange: (Boolean) -> Unit,
    onOpenSettings: () -> Unit
) {
    Column {
        SettingsToggleRow(
            label = "Mac 通知同步",
            checked = enabled,
            onCheckedChange = onCheckedChange
        )
        if (enabled && (!accessGranted || !postGranted)) {
            Row(
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (!accessGranted) "需要通知存取權" else "通知提醒被系統擋住",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.weight(1f)
                )
                FilledTonalButton(onClick = onOpenSettings) {
                    Text(actionLabel)
                }
            }
        }
    }
}

@Composable
private fun PermissionStatusRow(
    label: String,
    granted: Boolean,
    missingText: String,
    actionLabel: String = "開啟設定",
    onOpenSettings: () -> Unit
) {
    ListItem(
        headlineContent = { Text(label) },
        supportingContent = {
            Text(if (granted) "就緒" else missingText)
        },
        trailingContent = {
            if (!granted) {
                FilledTonalButton(onClick = onOpenSettings) {
                    Text(actionLabel)
                }
            }
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent)
    )
}

@Composable
private fun Touchpad(
    modifier: Modifier,
    onPointer: (InputPointerBody) -> Unit
) {
    Box(
        modifier = modifier
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(28.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(28.dp))
            .pointerInput(onPointer) {
                detectTapGestures(
                    onTap = { onPointer(InputPointerBody(btn = "left")) },
                    onDoubleTap = { onPointer(InputPointerBody(btn = "left")) }
                )
            }
            .pointerInput(onPointer) {
                awaitEachGesture {
                    while (true) {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.filter { it.pressed }
                        if (pressed.isEmpty()) break

                        if (pressed.size >= 2) {
                            val average = pressed.averagePositionChange()
                            if (average != Offset.Zero) {
                                onPointer(
                                    InputPointerBody(
                                        scrollX = (-average.x * 3f).toDouble(),
                                        scrollY = (-average.y * 3f).toDouble()
                                    )
                                )
                            }
                        } else {
                            val delta = pressed.first().positionChange()
                            if (delta != Offset.Zero) {
                                onPointer(InputPointerBody(dx = delta.x.toDouble(), dy = delta.y.toDouble()))
                            }
                        }
                        pressed.forEach(PointerInputChange::consume)
                    }
                }
            }
    )
}

@Composable
private fun KeyboardPanel(
    text: String,
    onTextChange: (String) -> Unit,
    onSendText: () -> Unit,
    onKey: (InputKeyBody) -> Unit
) {
    Column(
        modifier = Modifier.padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            listOf("esc", "tab", "delete").forEach { key ->
                FilledTonalButton(
                    onClick = { onKey(InputKeyBody(key)) },
                    modifier = Modifier.weight(1f)
                ) {
                    Text(
                        text = when (key) {
                            "delete" -> "Delete"
                            else -> key.uppercase()
                        }
                    )
                }
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            FilledTonalButton(onClick = { onKey(InputKeyBody("left")) }, modifier = Modifier.weight(1f)) {
                Text("←")
            }
            FilledTonalButton(onClick = { onKey(InputKeyBody("down")) }, modifier = Modifier.weight(1f)) {
                Text("↓")
            }
            FilledTonalButton(onClick = { onKey(InputKeyBody("up")) }, modifier = Modifier.weight(1f)) {
                Text("↑")
            }
            FilledTonalButton(onClick = { onKey(InputKeyBody("right")) }, modifier = Modifier.weight(1f)) {
                Text("→")
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            FilledTonalButton(onClick = { onKey(InputKeyBody("c", listOf("cmd"))) }, modifier = Modifier.weight(1f)) {
                Text("⌘C")
            }
            FilledTonalButton(onClick = { onKey(InputKeyBody("v", listOf("cmd"))) }, modifier = Modifier.weight(1f)) {
                Text("⌘V")
            }
            FilledTonalButton(onClick = { onKey(InputKeyBody("a", listOf("cmd"))) }, modifier = Modifier.weight(1f)) {
                Text("⌘A")
            }
        }

        OutlinedTextField(
            value = text,
            onValueChange = onTextChange,
            label = { Text("輸入文字") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text),
            singleLine = true,
            modifier = Modifier.fillMaxWidth()
        )

        Button(
            onClick = onSendText,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("送出")
        }
    }
}

@Composable
private fun PairingScreen(
    state: EdgeLinkUiState,
    actions: EdgeLinkActions
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp)
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("EdgeLink", style = MaterialTheme.typography.headlineMedium)
            Text(
                text = if (state.pairingSas.isEmpty()) {
                    "輸入 Mac 顯示的 9 碼 ID"
                } else {
                    "確認兩邊數字相同後按 Confirm"
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(28.dp),
            color = MaterialTheme.colorScheme.surfaceContainerLow
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Text(
                    text = displayDeviceIdInput(state.pairingHostIdInput),
                    style = MaterialTheme.typography.headlineMedium.copy(fontFamily = FontFamily.Monospace),
                    maxLines = 1
                )

                if (state.pairingSas.isNotEmpty()) {
                    Text(
                        text = state.pairingSas,
                        fontSize = 44.sp,
                        fontFamily = FontFamily.Monospace
                    )
                    if (state.pairingPeerName.isNotEmpty()) {
                        Text(
                            text = state.pairingPeerName,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }

        NumericPad(
            onDigit = actions::onPairDigit,
            onBackspace = actions::onPairBackspace,
            enabled = !state.isPairing || state.pairingSas.isEmpty()
        )

        if (state.canConfirmPairing) {
            Button(
                onClick = actions::onConfirmPairing,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(64.dp)
            ) {
                Text("Confirm", fontSize = 20.sp)
            }
        } else {
            Button(
                onClick = actions::onStartPairing,
                enabled = state.pairingHostIdInput.length == 9 && !state.isPairing,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(64.dp)
            ) {
                Text(if (state.isPairing) "配對中" else "開始配對", fontSize = 20.sp)
            }
        }

        if (state.connectionStatus.isNotBlank()) {
            Text(
                text = localizedStatus(state.connectionStatus),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun NumericPad(
    onDigit: (String) -> Unit,
    onBackspace: () -> Unit,
    enabled: Boolean
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        listOf(
            listOf("1", "2", "3"),
            listOf("4", "5", "6"),
            listOf("7", "8", "9")
        ).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                row.forEach { digit ->
                    Button(
                        onClick = { onDigit(digit) },
                        enabled = enabled,
                        modifier = Modifier
                            .weight(1f)
                            .height(60.dp)
                    ) {
                        Text(digit, fontSize = 24.sp)
                    }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            Box(modifier = Modifier.weight(1f))
            Button(
                onClick = { onDigit("0") },
                enabled = enabled,
                modifier = Modifier
                    .weight(1f)
                    .height(60.dp)
            ) {
                Text("0", fontSize = 24.sp)
            }
            Button(
                onClick = onBackspace,
                enabled = enabled,
                modifier = Modifier
                    .weight(1f)
                    .height(60.dp)
            ) {
                Text("⌫", fontSize = 24.sp)
            }
        }
    }
}

private data class MissingPermission(
    val title: String,
    val detail: String,
    val actionLabel: String,
    val onOpen: () -> Unit
)

private fun missingPermissions(state: EdgeLinkUiState, actions: EdgeLinkActions): List<MissingPermission> =
    buildList {
        if (state.notificationSyncEnabled && (!state.notificationAccessGranted || !state.notificationPostGranted)) {
            add(
                MissingPermission(
                    title = "通知同步",
                    detail = if (!state.notificationAccessGranted) "需要通知存取權" else "需要允許通知提醒",
                    actionLabel = permissionActionLabel(state),
                    onOpen = actions::onOpenNotificationSettings
                )
            )
        }
        if (!state.remoteInputAccessGranted) {
            add(
                MissingPermission(
                    title = "遠端輸入",
                    detail = "需要啟用輔助使用服務",
                    actionLabel = permissionActionLabel(state),
                    onOpen = actions::onOpenRemoteInputSettings
                )
            )
        }
        if (!state.screenDimmingAccessGranted) {
            add(
                MissingPermission(
                    title = "螢幕保持喚醒",
                    detail = "需要修改系統設定或顯示在其他應用程式上層",
                    actionLabel = permissionActionLabel(state),
                    onOpen = actions::onOpenScreenDimmingSettings
                )
            )
        }
        if (!state.smsAccessGranted) {
            add(
                MissingPermission(
                    title = "SMS",
                    detail = "需要簡訊權限",
                    actionLabel = permissionActionLabel(state),
                    onOpen = actions::onOpenSmsSettings
                )
            )
        }
    }

private fun permissionActionLabel(state: EdgeLinkUiState): String =
    if (state.shizukuAvailable && state.shizukuSupported && !state.shizukuPermissionRequestBlocked) {
        "修復"
    } else {
        "開啟設定"
    }

private fun shizukuStatusText(state: EdgeLinkUiState): String =
    when {
        !state.shizukuAvailable -> "未連線"
        !state.shizukuSupported -> "版本不支援"
        state.shizukuPermissionGranted -> when (state.shizukuUid) {
            0 -> "已授權：root"
            2000 -> "已授權：shell"
            null -> "已授權"
            else -> "已授權：uid ${state.shizukuUid}"
        }
        state.shizukuPermissionRequestBlocked -> "已拒絕"
        else -> "可授權"
    }

private val EdgeLinkUiState.canDisconnect: Boolean
    get() = connectionPhase == ConnectionPhase.Connected ||
        connectionPhase == ConnectionPhase.Connecting ||
        connectionPhase == ConnectionPhase.Handshaking ||
        connectionPhase == ConnectionPhase.Reconnecting

private fun localizedStatus(status: String): String =
    when (status) {
        "Starting" -> "啟動中"
        "Registering" -> "註冊裝置中"
        "No paired Mac" -> "尚未配對 Mac"
        "Invalid Mac ID" -> "Mac ID 不正確"
        "Opening pairing" -> "正在開啟配對"
        "Pairing failed" -> "配對失敗"
        "Waiting for Mac" -> "等待 Mac 確認"
        "Compare code" -> "比對確認碼"
        "Paired" -> "已配對"
        "Setup failed" -> "初始化失敗"
        "Reconnecting" -> "重新連線中"
        "Connecting relay" -> "連線到 relay"
        "Handshaking" -> "握手中"
        "Connected" -> "已連線"
        "Disconnected" -> "已中斷"
        else -> status
    }

private fun List<PointerInputChange>.averagePositionChange(): Offset {
    val total = fold(Offset.Zero) { partial, change -> partial + change.positionChange() }
    return Offset(total.x / size, total.y / size)
}

private fun displayDeviceIdInput(value: String): String =
    value.padEnd(9, '·').chunked(3).joinToString(" ")
