package dev.yab.browser.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.selection.toggleable
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.runtime.getValue
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.android.R

/** Phone SettingsInk and PenArt. Geometry and handlers stay owned by SettingsPresentation. */
@Composable internal fun settingsColors(): ColorScheme {
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    val ground = if (dark) Color(0xFF1C1C1E) else Color(0xFFF2F2F7)
    val group = if (dark) Color(0xFF2C2C2E) else Color.White
    val ink = if (dark) Color.White else Color(0xFF1C1C1E)
    return MaterialTheme.colorScheme.copy(background = ground, surface = group, surfaceContainer = group,
        surfaceContainerLow = group, surfaceContainerHigh = group, surfaceContainerHighest = group,
        primary = ink, onPrimary = ground, onSurface = ink,
        onSurfaceVariant = (if (dark) Color(0xFFEBEBF5) else Color(0xFF3C3C43)).copy(alpha = .72f), surfaceTint = Color.Transparent)
}

@Composable internal fun SettingsArt(title: String, side: Dp = 30.dp) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    val art = when (title) {
        "General" -> if (dark) R.drawable.settings_art_general_dark else R.drawable.settings_art_general
        "Search" -> if (dark) R.drawable.settings_art_search_dark else R.drawable.settings_art_search
        "Appearance" -> if (dark) R.drawable.settings_art_appearance_dark else R.drawable.settings_art_appearance
        "App Icon" -> if (dark) R.drawable.settings_art_appicon_dark else R.drawable.settings_art_appicon
        "Engine" -> if (dark) R.drawable.settings_art_engine_dark else R.drawable.settings_art_engine
        "Tabs", "Today" -> if (dark) R.drawable.settings_art_tabs_dark else R.drawable.settings_art_tabs
        "Sync" -> if (dark) R.drawable.settings_art_sync_dark else R.drawable.settings_art_sync
        "AI", "About a page", "On-device AI" -> if (dark) R.drawable.settings_art_ai_dark else R.drawable.settings_art_ai
        "Spaces" -> if (dark) R.drawable.settings_art_spaces_dark else R.drawable.settings_art_spaces
        "History" -> if (dark) R.drawable.settings_art_history_dark else R.drawable.settings_art_history
        "Passwords" -> if (dark) R.drawable.settings_art_passwords_dark else R.drawable.settings_art_passwords
        "Autofill" -> if (dark) R.drawable.settings_art_autofill_dark else R.drawable.settings_art_autofill
        "Privacy" -> if (dark) R.drawable.settings_art_privacy_dark else R.drawable.settings_art_privacy
        "About" -> if (dark) R.drawable.settings_art_about_dark else R.drawable.settings_art_about
        "Send Feedback" -> if (dark) R.drawable.settings_art_feedback_dark else R.drawable.settings_art_feedback
        "Extensions" -> if (dark) R.drawable.settings_art_extensions_dark else R.drawable.settings_art_extensions
        else -> null
    }
    if (art != null) {
        Surface(Modifier.size(side), shape = RoundedCornerShape(side * .25f),
            color = if (dark) Color(0xFF2B2B2F) else Color(0xFFFBFAF8),
            border = BorderStroke(maxOf(.5.dp, side / 56), (if (dark) Color.White else Color.Black).copy(alpha = .1f))) {
            Image(painterResource(art), null, Modifier.fillMaxSize())
        }
    }
}

@Composable internal fun SettingsHero(title: String) {
    Column(Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 18.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        val glyph = when (title) {
            "Today" -> YabGlyphs.SquareBehindSquare1
            "About a page" -> YabGlyphs.Sparkle
            "Agent", "Everything else" -> YabGlyphs.Agent
            "Private Tabs" -> YabGlyphs.Incognito
            else -> null
        }
        if (glyph != null) {
            val dark = MaterialTheme.colorScheme.background.luminance() < .2f
            val monochrome = title in listOf("About a page", "Agent", "Everything else")
            val tile = when {
                title == "Today" -> if (dark) Color(0xFFFF9230) else Color(0xFFFF8D28)
                monochrome -> if (dark) Color(0xFFF2F2F7) else Color(0xFF1C1C1E)
                else -> Color(0xFF8E8E93)
            }
            Box(Modifier.size(56.dp).background(tile, RoundedCornerShape(56.dp * .27f)), contentAlignment = Alignment.Center) {
                Icon(glyph, null, Modifier.size(56.dp * .58f), tint = if (monochrome && dark) Color.Black else Color.White)
            }
        } else SettingsArt(title, 56.dp)
        Text(title, Modifier.testTag("settings.hero.title"), fontSize = 22.sp, lineHeight = 27.sp, fontWeight = FontWeight.Bold)
        val blurb = when (title) {
            "Search" -> "Search the web, or ask a question from the address field."
            "Spaces" -> "Sets of tabs, each with its pins, its color and whose sign-ins."
            "AI" -> "Answers on this device, and Claude or ChatGPT on your Mac."
            "Passwords" -> "Passwords and passkeys from your configured Android provider."
            "Autofill" -> "Information offered by Android on supported webpage fields."
            else -> null
        }
        if (blurb != null) Text(blurb, Modifier.padding(horizontal = 24.dp), fontSize = 13.sp, lineHeight = 18.sp,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable internal fun SettingsActionRow(title: String, icon: ImageVector? = null, subtitle: String? = null,
    trailing: String? = null, danger: Boolean = false, art: Boolean = false, action: (() -> Unit)? = null) {
    val ink = if (danger) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
    Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).then(if (action == null) Modifier else Modifier.clickable(onClick = action))
        .padding(horizontal = 12.dp, vertical = if (subtitle == null) 0.dp else 7.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        if (art) SettingsArt(title) else icon?.let { SettingsRowIcon(it, ink) }
        Column(Modifier.weight(1f)) {
            Text(title, color = ink, fontSize = 17.sp, lineHeight = 21.sp)
            subtitle?.let { Text(it, fontSize = 13.sp, lineHeight = 16.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        trailing?.let { Text(it, fontSize = 17.sp, lineHeight = 21.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        if (action != null && !art) Icon(YabGlyphs.ChevronRight, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurface.copy(alpha = .35f))
    }
}

@Composable internal fun SettingsRowIcon(icon: ImageVector, tint: Color) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    Surface(Modifier.size(30.dp), shape = RoundedCornerShape(8.dp),
        color = Color(0xFF767680).copy(alpha = if (dark) .24f else .12f)) {
        Box(contentAlignment = Alignment.Center) { Icon(icon, null, Modifier.size(20.dp), tint = tint) }
    }
}

@Composable internal fun SettingsSwitch(checked: Boolean, change: (Boolean) -> Unit, enabled: Boolean = true) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    val reduced = LocalBrowserAccessibility.current.reduceMotion || !android.animation.ValueAnimator.areAnimatorsEnabled()
    // Measured from the current iOS 26.4 native toggle, including its pill thumb.
    val x by animateDpAsState(if (checked) 24.dp else 2.dp, tween(if (reduced) 0 else 180), label = "Settings switch")
    val off = if (dark) Color(0xFF656569) else Color(0xFFC5C5C7)
    val on = if (dark) Color(0xFF30D158) else Color(0xFF34C759)
    Box(Modifier.size(63.dp, 28.dp).background(if (checked) on else off, RoundedCornerShape(14.dp))
        .toggleable(checked, enabled = enabled, role = Role.Switch, onValueChange = change)) {
        Surface(Modifier.padding(top = 2.dp).offset(x = x).size(37.dp, 24.dp), shape = RoundedCornerShape(12.dp), color = Color.White) {}
    }
}
