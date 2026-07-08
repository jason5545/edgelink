package com.edgelink.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
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
    MaterialTheme {
        Surface {
            DeviceControlScreen(state = state, actions = actions)
        }
    }
}

data class EdgeLinkUiState(
    val localDeviceId: String = "",
    val peerName: String = "No paired Mac",
    val peerDeviceId: String = "",
    val connectionStatus: String = "Starting",
    val isConnected: Boolean = false,
    val pairingHostIdInput: String = "",
    val pairingSas: String = "",
    val pairingPeerName: String = "",
    val isPairing: Boolean = false,
    val canConfirmPairing: Boolean = false
)

interface EdgeLinkActions {
    fun onPointer(body: InputPointerBody)
    fun onKey(body: InputKeyBody)
    fun onText(body: InputTextBody)
    fun onPairDigit(digit: String)
    fun onPairBackspace()
    fun onStartPairing()
    fun onConfirmPairing()

    object Noop : EdgeLinkActions {
        override fun onPointer(body: InputPointerBody) = Unit
        override fun onKey(body: InputKeyBody) = Unit
        override fun onText(body: InputTextBody) = Unit
        override fun onPairDigit(digit: String) = Unit
        override fun onPairBackspace() = Unit
        override fun onStartPairing() = Unit
        override fun onConfirmPairing() = Unit
    }
}

@Composable
fun DeviceControlScreen(state: EdgeLinkUiState, actions: EdgeLinkActions) {
    var text by remember { mutableStateOf("") }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        DeviceCard(
            name = state.peerName,
            deviceId = state.peerDeviceId.ifEmpty { state.localDeviceId },
            status = state.connectionStatus,
            connected = state.isConnected
        )

        if (state.peerDeviceId.isEmpty()) {
            PairingPanel(
                state = state,
                actions = actions,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
            )
        } else {
            Touchpad(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                onPointer = actions::onPointer
            )

            KeyboardPanel(
                text = text,
                onTextChange = { value -> text = value },
                onSendText = {
                    if (text.isNotEmpty()) {
                        actions.onText(InputTextBody(text))
                        text = ""
                    }
                },
                onKey = actions::onKey
            )
        }
    }
}

@Composable
private fun DeviceCard(name: String, deviceId: String, status: String, connected: Boolean) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(8.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(
                modifier = Modifier
                    .size(12.dp)
                    .background(
                        if (connected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                        RoundedCornerShape(6.dp)
                    )
            )
            Text(
                text = status,
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Text(
            text = name,
            style = MaterialTheme.typography.titleLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
        Text(
            text = deviceId,
            style = MaterialTheme.typography.titleMedium.copy(fontFamily = FontFamily.Monospace)
        )
    }
}

@Composable
private fun Touchpad(
    modifier: Modifier,
    onPointer: (InputPointerBody) -> Unit
) {
    Box(
        modifier = modifier
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
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
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            listOf("esc", "tab", "delete").forEach { key ->
                FilledTonalButton(
                    onClick = { onKey(InputKeyBody(key)) },
                    modifier = Modifier.weight(1f)
                ) {
                    Text(key.uppercase())
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
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text),
            singleLine = true,
            modifier = Modifier.fillMaxWidth()
        )

        Button(
            onClick = onSendText,
            modifier = Modifier
                .fillMaxWidth()
                .height(64.dp)
        ) {
            Text("Send", fontSize = 20.sp)
        }
    }
}

@Composable
private fun PairingPanel(
    state: EdgeLinkUiState,
    actions: EdgeLinkActions,
    modifier: Modifier
) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
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
                    .height(72.dp)
            ) {
                Text("Confirm", fontSize = 22.sp)
            }
        } else {
            Button(
                onClick = actions::onStartPairing,
                enabled = state.pairingHostIdInput.length == 9 && !state.isPairing,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(72.dp)
            ) {
                Text("Pair", fontSize = 22.sp)
            }
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
                            .height(64.dp)
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
                    .height(64.dp)
            ) {
                Text("0", fontSize = 24.sp)
            }
            Button(
                onClick = onBackspace,
                enabled = enabled,
                modifier = Modifier
                    .weight(1f)
                    .height(64.dp)
            ) {
                Text("⌫", fontSize = 24.sp)
            }
        }
    }
}

private fun List<PointerInputChange>.averagePositionChange(): Offset {
    val total = fold(Offset.Zero) { partial, change -> partial + change.positionChange() }
    return Offset(total.x / size, total.y / size)
}

private fun displayDeviceIdInput(value: String): String =
    value.padEnd(9, '·').chunked(3).joinToString(" ")
