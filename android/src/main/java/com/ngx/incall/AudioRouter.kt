package com.ngx.incall

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Call audio routing on Android (FR-CALL-04): earpiece, speaker or a Bluetooth headset, and notice when the
 * route changes underneath the call (headset connected or removed). Wired and USB headsets take over the
 * built-in route and are reported as [AudioRoute.EARPIECE] (the "not speaker, not Bluetooth" route).
 * Uses the communication-device API on Android 12+, speakerphone / Bluetooth SCO before that.
 */
class AudioRouter internal constructor(context: Context) {
    private val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())

    /** Called on the main thread whenever the route changes, for any reason. */
    var onChange: ((AudioRoute) -> Unit)? = null

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = changed()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = changed()
    }
    private var inCall = false

    internal fun changed() { main.post { onChange?.invoke(current) } }

    /** Put audio in call mode; the SDK calls this when a call starts. */
    fun startCall() {
        if (inCall) return
        inCall = true
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        am.registerAudioDeviceCallback(deviceCallback, main)
    }

    /** Give audio back to the system when the call ends. */
    fun endCall() {
        if (!inCall) return
        inCall = false
        am.unregisterAudioDeviceCallback(deviceCallback)
        if (Build.VERSION.SDK_INT >= 31) am.clearCommunicationDevice()
        else {
            @Suppress("DEPRECATION") run { am.isSpeakerphoneOn = false; am.stopBluetoothSco(); am.isBluetoothScoOn = false }
        }
        am.mode = AudioManager.MODE_NORMAL
    }

    /** Routes the user can pick right now. */
    val available: List<AudioRoute>
        get() = if (Build.VERSION.SDK_INT >= 31) {
            am.availableCommunicationDevices.mapNotNull { routeOf(it.type) }.distinct().sortedBy { it.ordinal }
        } else {
            val outs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            buildList {
                if (outs.any { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE || routeOf(it.type) == AudioRoute.EARPIECE }) add(AudioRoute.EARPIECE)
                add(AudioRoute.SPEAKER)
                if (outs.any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }) add(AudioRoute.BLUETOOTH)
            }.sortedBy { it.ordinal }
        }

    /** Where audio is going now. */
    @Suppress("DEPRECATION")
    val current: AudioRoute
        get() = if (Build.VERSION.SDK_INT >= 31) am.communicationDevice?.let { routeOf(it.type) } ?: AudioRoute.EARPIECE
        else if (am.isBluetoothScoOn) AudioRoute.BLUETOOTH else if (am.isSpeakerphoneOn) AudioRoute.SPEAKER else AudioRoute.EARPIECE

    fun set(route: AudioRoute) {
        if (Build.VERSION.SDK_INT >= 31) {
            // Prefer a wired / USB headset over the earpiece when both map to EARPIECE.
            val device = am.availableCommunicationDevices
                .filter { routeOf(it.type) == route }
                .minByOrNull { if (it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE) 1 else 0 }
                ?: throw InCallException.MediaFailed("no ${route.name.lowercase()} audio device available")
            am.setCommunicationDevice(device)
        } else {
            @Suppress("DEPRECATION")
            when (route) {
                AudioRoute.SPEAKER -> { am.stopBluetoothSco(); am.isBluetoothScoOn = false; am.isSpeakerphoneOn = true }
                AudioRoute.EARPIECE -> { am.stopBluetoothSco(); am.isBluetoothScoOn = false; am.isSpeakerphoneOn = false }
                AudioRoute.BLUETOOTH -> {
                    if (am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).none { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO })
                        throw InCallException.MediaFailed("no Bluetooth headset connected")
                    am.isSpeakerphoneOn = false; am.startBluetoothSco(); am.isBluetoothScoOn = true
                }
            }
        }
        changed()
    }

    internal companion object {
        fun routeOf(type: Int): AudioRoute? = when (type) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> AudioRoute.SPEAKER
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE, AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET -> AudioRoute.EARPIECE
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_HEARING_AID, 26 /* TYPE_BLE_HEADSET (API 31) */ -> AudioRoute.BLUETOOTH
            else -> null
        }
    }
}
