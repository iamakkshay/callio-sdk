package com.ngx.incall.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ngx.incall.AudioRoute
import com.ngx.incall.CallDirection
import com.ngx.incall.CallState

/** The in-call screen: who, status and duration, quality, and controls (mute, keypad, audio route, hold, end). */
@Composable
fun CallScreen(model: CallViewModel, modifier: Modifier = Modifier) {
    val ui by model.ui.collectAsState()
    val theme = LocalInCallTheme.current
    val strings = LocalInCallStrings.current
    var keypad by remember { mutableStateOf(false) }
    var dialed by remember { mutableStateOf("") }
    val peer = ui.call?.peer
    val bars = CallPresentation.bars(ui.quality)

    Column(
        modifier.fillMaxSize().background(theme.background).padding(horizontal = 24.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(0.4f))
        Box(Modifier.size(112.dp).clip(CircleShape).background(theme.surface), contentAlignment = Alignment.Center) {
            Text(CallPresentation.initials(peer?.displayName ?: ""), color = theme.onSurface, fontSize = 40.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(18.dp))
        Text(peer?.displayName ?: "", color = theme.onSurface, fontSize = 28.sp, fontWeight = FontWeight.SemiBold)
        Text(CallPresentation.status(ui.state, ui.call?.direction ?: CallDirection.OUTGOING, ui.seconds, strings), color = theme.secondaryText, fontSize = 17.sp)
        if (ui.state is CallState.Connected) QualityBars(bars, Modifier.padding(top = 12.dp).semantics { contentDescription = strings[if (bars >= 3) "quality.good" else if (bars == 2) "quality.fair" else "quality.poor"] })
        if (keypad) {
            Text(dialed, color = theme.onSurface, fontSize = 24.sp, modifier = Modifier.padding(top = 16.dp))
            Keypad { d -> dialed += d; model.sendDtmf(d) }
        }
        Spacer(Modifier.weight(1f))
        if (ui.state is CallState.Ringing && ui.call?.direction == CallDirection.INCOMING) {
            Row(horizontalArrangement = Arrangement.spacedBy(64.dp)) {
                RoundButton(Icons.Filled.CallEnd, strings["decline"], theme.danger) { model.decline() }
                RoundButton(Icons.Filled.Call, strings["answer"], theme.success) { model.answer() }
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                ToggleButton(if (ui.muted) Icons.Filled.MicOff else Icons.Filled.Mic, strings[if (ui.muted) "unmute" else "mute"], ui.muted) { model.toggleMute() }
                ToggleButton(Icons.Filled.Dialpad, strings[if (keypad) "hideKeypad" else "keypad"], keypad) { keypad = !keypad }
                RouteButton(ui.route, ui.routes) { model.setRoute(it) }
                ToggleButton(if (ui.onHold) Icons.Filled.PlayArrow else Icons.Filled.Pause, strings[if (ui.onHold) "resume" else "hold"], ui.onHold) { model.toggleHold() }
            }
            Spacer(Modifier.height(22.dp))
            RoundButton(Icons.Filled.CallEnd, strings["end"], theme.danger) { model.hangup() }
        }
    }
}

/** Incoming call inside the app (the system notification handles the lock screen). */
@Composable
fun IncomingCallScreen(model: CallViewModel, modifier: Modifier = Modifier) = CallScreen(model, modifier)

@Composable
private fun RouteButton(route: AudioRoute, routes: List<AudioRoute>, onPick: (AudioRoute) -> Unit) {
    val strings = LocalInCallStrings.current
    if (routes.size > 2) {
        var open by remember { mutableStateOf(false) }
        Box {
            ToggleButton(icon(route), strings["audio"], route != AudioRoute.EARPIECE) { open = true }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                routes.forEach { r ->
                    DropdownMenuItem(text = { Text(strings[r.name.lowercase()]) }, leadingIcon = { Icon(icon(r), null) }, onClick = { open = false; onPick(r) })
                }
            }
        }
    } else {
        ToggleButton(Icons.Filled.VolumeUp, strings["speaker"], route == AudioRoute.SPEAKER) {
            onPick(if (route == AudioRoute.SPEAKER) AudioRoute.EARPIECE else AudioRoute.SPEAKER)
        }
    }
}

private fun icon(r: AudioRoute): ImageVector = when (r) {
    AudioRoute.SPEAKER -> Icons.Filled.VolumeUp
    AudioRoute.EARPIECE -> Icons.Filled.PhoneAndroid
    AudioRoute.BLUETOOTH -> Icons.Filled.Headset
}

@Composable
private fun QualityBars(bars: Int, modifier: Modifier = Modifier) {
    val theme = LocalInCallTheme.current
    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {   // signal bars don't mirror
        Row(modifier, horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.Bottom) {
            for (i in 1..3) Box(Modifier.width(5.dp).height((5 + i * 4).dp).clip(RoundedCornerShape(1.5.dp))
                .background(if (i <= bars) (if (bars == 1) theme.danger else theme.success) else theme.surface))
        }
    }
}

@Composable
private fun ToggleButton(icon: ImageVector, label: String, on: Boolean, onClick: () -> Unit) {
    val theme = LocalInCallTheme.current
    Column(
        Modifier.widthIn(min = 64.dp).clickable(onClick = onClick).semantics { selected = on },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.size(60.dp).clip(CircleShape).background(if (on) theme.onSurface else theme.surface), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = if (on) theme.background else theme.onSurface)
        }
        Text(label, color = theme.secondaryText, fontSize = 12.sp, maxLines = 1, modifier = Modifier.padding(top = 6.dp))
    }
}

@Composable
private fun RoundButton(icon: ImageVector, label: String, fill: Color, onClick: () -> Unit) {
    val theme = LocalInCallTheme.current
    Column(Modifier.clickable(onClick = onClick).semantics { contentDescription = label }, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(72.dp).clip(CircleShape).background(fill), contentAlignment = Alignment.Center) { Icon(icon, null, tint = Color.White) }
        Text(label, color = theme.secondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
    }
}

@Composable
private fun Keypad(onKey: (String) -> Unit) {
    val theme = LocalInCallTheme.current
    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {   // a keypad reads the same in Arabic
        Column(Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"), listOf("*", "0", "#")).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(22.dp)) {
                    row.forEach { k ->
                        Box(Modifier.size(64.dp).clip(CircleShape).background(theme.surface).clickable { onKey(k) }, contentAlignment = Alignment.Center) {
                            Text(k, color = theme.onSurface, fontSize = 28.sp)
                        }
                    }
                }
            }
        }
    }
}
