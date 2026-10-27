package com.ngx.incall

import android.media.AudioDeviceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AudioRouterTest {
    @Test fun devicesMapToTheThreeRoutes() {
        assertEquals(AudioRoute.SPEAKER, AudioRouter.routeOf(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER))
        assertEquals(AudioRoute.EARPIECE, AudioRouter.routeOf(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE))
        assertEquals("a wired headset is the not-speaker route", AudioRoute.EARPIECE, AudioRouter.routeOf(AudioDeviceInfo.TYPE_WIRED_HEADSET))
        assertEquals(AudioRoute.BLUETOOTH, AudioRouter.routeOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO))
        assertEquals("BLE audio headsets count as Bluetooth", AudioRoute.BLUETOOTH, AudioRouter.routeOf(26))
        assertNull("A2DP can't carry a call's microphone", AudioRouter.routeOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP))
    }
}
