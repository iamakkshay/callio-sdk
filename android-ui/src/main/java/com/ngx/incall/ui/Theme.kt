// Prebuilt UI (FR-SDK-03): themeable Compose screens for calls and chat on top of incall-sdk. Brand it with an
// InCallTheme; strings follow the device language (English / Arabic, right-to-left) or InCallStrings.
package com.ngx.incall.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp

data class InCallTheme(
    val accent: Color = Color(0xFF0F9F6E),
    val background: Color = Color(0xFF1A1612),
    val surface: Color = Color(0xFF2A231C),
    val onSurface: Color = Color(0xFFF3ECE2),
    val secondaryText: Color = Color(0xFFB3A594),
    val danger: Color = Color(0xFFDC3636),
    val success: Color = Color(0xFF0F9F6E),
    val myBubble: Color = accent,
    val peerBubble: Color = surface,
    val cornerRadius: Dp = 18.dp,
) {
    companion object {
        val Standard = InCallTheme()
        val Light = InCallTheme(background = Color.White, surface = Color(0xFFF2F2F2), onSurface = Color(0xFF1A1A1A), secondaryText = Color(0xFF666666))
    }
}

val LocalInCallTheme = staticCompositionLocalOf { InCallTheme.Standard }
val LocalInCallStrings = staticCompositionLocalOf { InCallStrings() }

/** Wrap the prebuilt screens to brand them or fix their language (and its layout direction). */
@Composable
fun InCallUi(theme: InCallTheme = InCallTheme.Standard, strings: InCallStrings = InCallStrings(), content: @Composable () -> Unit) {
    CompositionLocalProvider(
        LocalInCallTheme provides theme,
        LocalInCallStrings provides strings,
        LocalLayoutDirection provides if (strings.isRightToLeft) LayoutDirection.Rtl else LayoutDirection.Ltr,
        content = content,
    )
}
