package com.clarigo.callio.demo

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ngx.incall.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

sealed interface Screen {
    data object SignIn : Screen
    data object Home : Screen
    data class Chat(val contact: Contact) : Screen
    data class InCall(val callId: String) : Screen
}

data class DemoState(
    val screen: Screen = Screen.SignIn,
    val busy: Boolean = false,
    val error: String? = null,
    val me: String? = null,
    val registration: RegistrationState = RegistrationState.OFFLINE,
    val contacts: List<Contact> = emptyList(),
    val presence: Map<String, Boolean> = emptyMap(),
    val activeCall: ActiveCall? = null,   // set while a call is on, whichever screen is showing
)

data class ActiveCall(val id: String, val peer: Contact)

/** Owns the one InCallClient for the signed-in user and the screen the demo shows. */
class DemoViewModel(app: Application) : AndroidViewModel(app), InCallListener {
    private val _state = MutableStateFlow(DemoState())
    val state: StateFlow<DemoState> = _state.asStateFlow()

    var client: InCallClient? = null
        private set

    fun signIn(server: String, org: String, user: String, password: String) {
        val base = server.trim().trimEnd('/')
        _state.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                DemoLogin.token(base, org, user, password)   // fail fast on wrong details
                // The SDK asks for a token whenever it needs one. A real app asks its own server here.
                val c = InCallClient(getApplication(), InCallConfig(baseUrl = base) { DemoLogin.token(base, org, user, password) })
                c.addListener(this@DemoViewModel)
                client = c
                c.start()
                c.startPresenceUpdates()
                _state.update { it.copy(busy = false, screen = Screen.Home, me = c.session?.user ?: user, contacts = contactsOf(c)) }
            } catch (e: Exception) {
                client?.removeListener(this@DemoViewModel)
                client = null
                _state.update { it.copy(busy = false, error = e.message ?: "Sign-in failed") }
            }
        }
    }

    fun call(contact: Contact) {
        val c = client ?: return
        viewModelScope.launch {
            runCatching { c.dial(contact) }
                .onSuccess { call -> _state.update { it.copy(screen = Screen.InCall(call.id), activeCall = ActiveCall(call.id, call.peer), error = null) } }
                .onFailure { e -> _state.update { it.copy(error = e.message ?: "Call failed") } }
        }
    }

    fun openChat(contact: Contact) = _state.update { it.copy(screen = Screen.Chat(contact), error = null) }

    /** Back to the call that's on, from chat or the contact list. */
    fun returnToCall() = _state.update { s -> s.activeCall?.let { s.copy(screen = Screen.InCall(it.id)) } ?: s }

    fun back() = _state.update { it.copy(screen = if (client != null) Screen.Home else Screen.SignIn) }

    fun signOut() {
        val c = client ?: return
        client = null
        c.removeListener(this)
        c.stopPresenceUpdates()
        viewModelScope.launch { runCatching { c.currentCall?.hangup() }; runCatching { c.stop() } }   // end any call first
        _state.value = DemoState()
    }

    private fun contactsOf(c: InCallClient): List<Contact> {
        val s = c.session ?: return emptyList()
        return (s.peers + s.directory).distinctBy { it.sipUser }.filter { it.sipUser != s.sipUser }
    }

    override fun onRegistrationChanged(state: RegistrationState) = _state.update { it.copy(registration = state) }

    override fun onIncomingCall(call: Call) = _state.update { it.copy(screen = Screen.InCall(call.id), activeCall = ActiveCall(call.id, call.peer)) }

    override fun onCallStateChanged(call: Call) {
        val ended = call.state as? CallState.Ended ?: return
        val who = call.peer.displayName
        val why = when (ended.reason) {
            CallEndReason.BUSY -> "$who is on another call"
            CallEndReason.DECLINED -> if (call.direction == CallDirection.OUTGOING) "$who declined the call" else null
            CallEndReason.NO_ANSWER -> "$who didn't answer"
            CallEndReason.UNREACHABLE -> "Couldn't reach $who"
            CallEndReason.MISSED -> "Missed call from $who"
            CallEndReason.ENDED -> null
        }
        _state.update { s -> s.copy(error = why, activeCall = if (s.activeCall?.id == call.id) null else s.activeCall) }
        viewModelScope.launch {
            delay(1500)   // leave "Call ended" on screen for a moment; only the call screen moves on by itself
            _state.update { s -> if (s.screen == Screen.InCall(call.id)) s.copy(screen = Screen.Home) else s }
        }
    }

    override fun onPresenceChanged(presence: Map<String, Boolean>) = _state.update { it.copy(presence = presence) }

    override fun onFailure(error: InCallException) = _state.update { it.copy(error = error.message) }

    override fun onCleared() { signOut() }
}
