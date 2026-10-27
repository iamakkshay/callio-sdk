package com.ngx.incall.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.ngx.incall.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Messages with one contact for the prebuilt chat screen. */
class ChatViewModel(private val client: InCallClient, contact: Contact) : ViewModel(), InCallListener {
    val thread: ChatThread = client.thread(contact)
    private val _messages = MutableStateFlow(thread.messages)
    val messages: StateFlow<List<Message>> = _messages.asStateFlow()
    private var typingSent = false

    init { client.addListener(this) }

    fun send(text: String) = viewModelScope.launch {
        val t = text.trim()
        if (t.isEmpty()) return@launch
        runCatching { thread.send(t) }
        _messages.value = thread.messages
        typing(false)
    }

    fun share(location: SharedLocation) = viewModelScope.launch { runCatching { thread.sendLocation(location) }; _messages.value = thread.messages }

    fun typing(on: Boolean) {
        if (on == typingSent) return
        typingSent = on
        viewModelScope.launch { thread.setTyping(on) }
    }

    override fun onMessage(message: Message, thread: ChatThread) { if (thread === this.thread) _messages.value = thread.messages }
    override fun onMessageStatusChanged(message: Message) { _messages.value = thread.messages }
    override fun onCleared() { client.removeListener(this) }
}

/** The chat screen: bubbles, location cards, a composer. [onShareLocation] lets the host app get the location its
 *  own way (permission prompt, picker); [onOpenLocation] opens it in the host's map. */
@Composable
fun ChatScreen(
    model: ChatViewModel,
    modifier: Modifier = Modifier,
    onShareLocation: (suspend () -> SharedLocation?)? = null,
    onOpenLocation: ((SharedLocation) -> Unit)? = null,
) {
    val messages by model.messages.collectAsState()
    val theme = LocalInCallTheme.current
    val strings = LocalInCallStrings.current
    var draft by remember { mutableStateOf("") }
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(messages.size) { if (messages.isNotEmpty()) list.animateScrollToItem(messages.size - 1) }

    Column(modifier.fillMaxSize().background(theme.background)) {
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(messages, key = { it.id }) { m -> ChatBubble(m, onOpenLocation) }
        }
        Row(Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (onShareLocation != null) {
                IconButton(onClick = { scope.launch { onShareLocation()?.let { model.share(it) } } }) {
                    Icon(Icons.Filled.LocationOn, contentDescription = strings["shareLocation"], tint = theme.accent)
                }
            }
            TextField(
                value = draft,
                onValueChange = { draft = it; model.typing(it.isNotEmpty()) },
                placeholder = { Text(strings["message"]) },
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(theme.cornerRadius),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = theme.surface, unfocusedContainerColor = theme.surface,
                    focusedTextColor = theme.onSurface, unfocusedTextColor = theme.onSurface,
                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
                ),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { model.send(draft); draft = "" }),
            )
            IconButton(onClick = { model.send(draft); draft = "" }, enabled = draft.isNotBlank()) {
                Icon(Icons.Filled.Send, contentDescription = strings["send"], tint = if (draft.isBlank()) theme.secondaryText else theme.accent)
            }
        }
    }
}

/** One message: text, or a location card that opens the host's map. */
@Composable
fun ChatBubble(message: Message, onOpenLocation: ((SharedLocation) -> Unit)? = null) {
    val theme = LocalInCallTheme.current
    val strings = LocalInCallStrings.current
    val mine = message.from == MessageSender.ME
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
        Column(
            Modifier.widthIn(max = 300.dp)
                .background(if (mine) theme.myBubble else theme.peerBubble, RoundedCornerShape(theme.cornerRadius))
                .padding(horizontal = 14.dp, vertical = 9.dp),
            horizontalAlignment = if (mine) Alignment.End else Alignment.Start,
        ) {
            val color = if (mine) Color.White else theme.onSurface
            val loc = message.location
            if (loc != null) {
                Row(Modifier.clickable(enabled = onOpenLocation != null) { onOpenLocation?.invoke(loc) }, verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Place, null, tint = color)
                    Text(loc.label.ifEmpty { strings["location"] }, color = color, modifier = Modifier.padding(start = 6.dp))
                }
            } else Text(message.text ?: "", color = color)
            if (mine && message.status == MessageStatus.FAILED) Text(strings["failed"], color = theme.danger, style = MaterialTheme.typography.labelSmall)
        }
    }
}
