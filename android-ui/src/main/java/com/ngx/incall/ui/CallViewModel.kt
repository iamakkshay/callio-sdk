package com.ngx.incall.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.ngx.incall.*
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class CallUiState(
    val call: Call? = null,
    val state: CallState = CallState.Ended(CallEndReason.ENDED),
    val seconds: Long = 0,
    val muted: Boolean = false,
    val onHold: Boolean = false,
    val quality: CallQuality? = null,
    val route: AudioRoute = AudioRoute.EARPIECE,
    val routes: List<AudioRoute> = emptyList(),
)

/** Live state of the current call for the prebuilt screens. Listens to the client alongside the app's listeners. */
class CallViewModel(private val client: InCallClient) : ViewModel(), InCallListener {
    private val _ui = MutableStateFlow(CallUiState())
    val ui: StateFlow<CallUiState> = _ui.asStateFlow()
    private var clock: Job? = null

    init {
        client.addListener(this)
        client.currentCall?.let(::attach)
        _ui.update { it.copy(route = client.audio.current, routes = client.audio.available) }
    }

    private fun attach(c: Call) {
        _ui.update { it.copy(call = c, state = c.state, muted = c.isMuted, onHold = c.isOnHold, seconds = 0) }
        if (c.state is CallState.Connected) startClock()
    }

    private fun startClock() {
        if (clock != null) return
        val start = System.currentTimeMillis()
        clock = viewModelScope.launch { while (true) { _ui.update { it.copy(seconds = (System.currentTimeMillis() - start) / 1000) }; delay(1000) } }
    }

    fun toggleMute() = viewModelScope.launch { _ui.value.call?.let { it.setMuted(!it.isMuted); _ui.update { s -> s.copy(muted = it.isMuted) } } }
    fun toggleHold() = viewModelScope.launch { _ui.value.call?.let { it.setHold(!it.isOnHold); _ui.update { s -> s.copy(onHold = it.isOnHold) } } }
    fun setRoute(r: AudioRoute) = viewModelScope.launch { runCatching { _ui.value.call?.setAudioRoute(r) } }
    fun sendDtmf(tone: String) = viewModelScope.launch { _ui.value.call?.sendDtmf(tone) }
    fun hangup() = viewModelScope.launch { _ui.value.call?.hangup() }
    fun answer() = viewModelScope.launch { runCatching { _ui.value.call?.answer() } }
    fun decline() = viewModelScope.launch { _ui.value.call?.decline() }

    override fun onIncomingCall(call: Call) { clock?.cancel(); clock = null; attach(call) }
    override fun onCallStateChanged(call: Call) {
        if (_ui.value.call?.id != call.id) { clock?.cancel(); clock = null; _ui.update { it.copy(call = call, seconds = 0) } }
        _ui.update { it.copy(state = call.state) }
        when (call.state) { is CallState.Connected -> startClock(); is CallState.Ended -> { clock?.cancel(); clock = null }; else -> {} }
    }
    override fun onCallQualityUpdated(quality: CallQuality) = _ui.update { it.copy(quality = quality) }
    override fun onAudioRouteChanged(route: AudioRoute) = _ui.update { it.copy(route = route, routes = client.audio.available) }

    override fun onCleared() { client.removeListener(this) }
}
