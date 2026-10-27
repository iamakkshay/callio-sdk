package com.clarigo.callio.demo

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.clickable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Email
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ngx.incall.Contact
import com.ngx.incall.InCallClient
import com.ngx.incall.RegistrationState
import com.ngx.incall.ui.CallScreen
import com.ngx.incall.ui.CallViewModel
import com.ngx.incall.ui.ChatScreen
import com.ngx.incall.ui.ChatViewModel
import com.ngx.incall.ui.InCallUi

private val Brand = Color(0xFF0F9F6E)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val perms = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            if (Build.VERSION.SDK_INT >= 31) add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {}.launch(perms.toTypedArray())
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Brand)) {
                Surface(Modifier.fillMaxSize()) { DemoApp() }
            }
        }
    }
}

@Composable
fun DemoApp(vm: DemoViewModel = viewModel()) {
    val s by vm.state.collectAsState()
    // While a call is on, Back never leaves it: from the call screen it does nothing, from chat it returns to the call.
    BackHandler(enabled = s.screen is Screen.InCall) {}
    BackHandler(enabled = s.screen is Screen.Chat) { if (s.activeCall != null) vm.returnToCall() else vm.back() }
    when (val screen = s.screen) {
        Screen.SignIn -> SignInScreen(s) { server, org, user, pw -> vm.signIn(server, org, user, pw) }
        Screen.Home -> Column(Modifier.fillMaxSize()) {
            ReturnToCallBar(s, vm::returnToCall)
            HomeScreen(s, onCall = vm::call, onChat = vm::openChat, onSignOut = vm::signOut)
        }
        is Screen.Chat -> vm.client?.let { client ->
            Column(Modifier.fillMaxSize()) {
                ReturnToCallBar(s, vm::returnToCall)
                ChatPane(client, screen.contact,
                    onBack = { if (s.activeCall != null) vm.returnToCall() else vm.back() },
                    onCall = { if (s.activeCall != null) vm.returnToCall() else vm.call(screen.contact) })
            }
        }
        is Screen.InCall -> vm.client?.let { client ->
            // The SDK's ready-made call screen: answer/decline, mute, speaker/Bluetooth, keypad, hold, end.
            val model = viewModel(key = "call-${System.identityHashCode(client)}-${screen.callId}") { CallViewModel(client) }
            Column(Modifier.fillMaxSize()) {
                s.activeCall?.let { call ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Spacer(Modifier.weight(1f))
                        // Chat with the same person without leaving the call; the green bar brings you back.
                        TextButton(onClick = { vm.openChat(call.peer) }) {
                            Icon(Icons.Filled.Email, contentDescription = null)
                            Spacer(Modifier.width(6.dp))
                            Text("Chat")
                        }
                    }
                }
                Box(Modifier.weight(1f)) { InCallUi { CallScreen(model, Modifier.fillMaxSize()) } }
            }
        }
    }
}

/** A green bar on every screen but the call itself while a call is on: tap to go back to it. */
@Composable
private fun ReturnToCallBar(s: DemoState, onReturn: () -> Unit) {
    val call = s.activeCall ?: return
    Row(
        Modifier.fillMaxWidth().background(Brand).clickable(onClick = onReturn).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Call, contentDescription = null, tint = Color.White)
        Text("On call with ${call.peer.displayName} · tap to return", color = Color.White, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = 10.dp))
    }
}

@Composable
private fun SignInScreen(s: DemoState, onSignIn: (String, String, String, String) -> Unit) {
    var server by rememberSaveable { mutableStateOf("http://10.0.2.2:8080") }   // the host machine, from the emulator
    var org by rememberSaveable { mutableStateOf("lab") }
    var user by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    Column(
        Modifier.fillMaxSize().padding(24.dp).imePadding(),
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
    ) {
        Text("Callio Demo", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        Text("Sign in with a user from your Callio organisation or developer sandbox.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedTextField(server, { server = it }, Modifier.fillMaxWidth(), label = { Text("Server") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        OutlinedTextField(org, { org = it }, Modifier.fillMaxWidth(), label = { Text("Organisation") }, singleLine = true)
        OutlinedTextField(user, { user = it }, Modifier.fillMaxWidth(), label = { Text("Username") }, singleLine = true)
        OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), label = { Text("Password") }, singleLine = true,
            visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        s.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button(
            onClick = { onSignIn(server, org, user, password) },
            enabled = !s.busy && server.isNotBlank() && user.isNotBlank() && password.isNotBlank(),
            modifier = Modifier.fillMaxWidth(),
        ) { Text(if (s.busy) "Signing in…" else "Sign in") }
    }
}

@Composable
private fun HomeScreen(s: DemoState, onCall: (Contact) -> Unit, onChat: (Contact) -> Unit, onSignOut: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(s.me ?: "", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                val (label, colour) = when (s.registration) {
                    RegistrationState.REGISTERED -> "Online · ready for calls" to Brand
                    RegistrationState.CONNECTING -> "Connecting…" to Color(0xFFE0A100)
                    RegistrationState.OFFLINE -> "Offline" to MaterialTheme.colorScheme.error
                }
                Text(label, color = colour, style = MaterialTheme.typography.bodySmall)
            }
            TextButton(onClick = onSignOut) { Text("Sign out") }
        }
        s.error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }
        Text("Contacts", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 20.dp, bottom = 8.dp))
        if (s.contacts.isEmpty()) Text("No one to contact yet. Contact rules decide who each user can reach.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(s.contacts, key = { it.sipUser }) { c -> ContactRow(c, s.presence[c.sipUser], onCall, onChat) }
        }
    }
}

@Composable
private fun ContactRow(c: Contact, online: Boolean?, onCall: (Contact) -> Unit, onChat: (Contact) -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(10.dp).background(if (online == true) Brand else Color.Gray, CircleShape))
            Column(Modifier.weight(1f).padding(start = 12.dp)) {
                Text(c.displayName, fontWeight = FontWeight.SemiBold)
                Text("${c.userType.wire} · ext ${c.sipUser}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            TextButton(onClick = { onChat(c) }) { Text("Chat") }
            Button(onClick = { onCall(c) }) { Text("Call") }
        }
    }
}

@Composable
private fun ChatPane(client: InCallClient, contact: Contact, onBack: () -> Unit, onCall: () -> Unit) {
    val context = LocalContext.current
    val model = viewModel(key = "chat-${System.identityHashCode(client)}-${contact.sipUser}") { ChatViewModel(client, contact) }
    Column(Modifier.fillMaxSize().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
            Text(contact.displayName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            IconButton(onClick = onCall) { Icon(Icons.Filled.Call, contentDescription = "Call", tint = Brand) }
        }
        Box(Modifier.weight(1f)) {
            InCallUi {
                // The SDK's ready-made chat: bubbles, read ticks, location cards and a composer.
                ChatScreen(
                    model,
                    Modifier.fillMaxSize(),
                    onShareLocation = { lastLocation(context) },
                    onOpenLocation = { loc ->
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("geo:${loc.lat},${loc.lng}?q=${loc.lat},${loc.lng}")))
                    },
                )
            }
        }
    }
}
