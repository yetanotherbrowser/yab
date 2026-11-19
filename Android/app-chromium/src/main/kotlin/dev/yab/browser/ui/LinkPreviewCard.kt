package dev.yab.browser.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import android.view.View
import android.view.ViewGroup
import dev.yab.browser.engine.CefriumLinkPreview

/** One accessible commit action; the preview document cannot be interacted with. */
@Composable
fun LinkPreviewCard(preview: CefriumLinkPreview, commit: () -> Unit, released: () -> Unit) {
    val page by preview.page.collectAsState()
    val onCommit by rememberUpdatedState(commit)
    val onReleased by rememberUpdatedState(released)
    DisposableEffect(preview) { onDispose { onReleased() } }
    Box(Modifier.fillMaxWidth().padding(bottom = 12.dp).clip(RoundedCornerShape(16.dp))) {
      Column {
        // The Cefrium preview browser renders into its surface container; the
        // overlay keeps every tap, so the document never takes focus.
        AndroidView(modifier = Modifier.fillMaxWidth().heightIn(min = 160.dp, max = 240.dp).height(220.dp), factory = { context ->
            preview.session.surfaceContainer.apply {
                isFocusable = false; isFocusableInTouchMode = false
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
                setOnTouchListener { _, _ -> true }
            }
        }, update = { }, onReset = null, onRelease = { })
        if (page.loading) LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        Text(if (page.failed) "Preview unavailable" else page.title.ifEmpty { preview.url },
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp), maxLines = 2,
            style = MaterialTheme.typography.bodyMedium)
      }
      // The overlay, rather than the native document, owns every tap and long press.
      Box(Modifier.matchParentSize().testTag("link.preview").clickable { onCommit() }.clearAndSetSemantics {
          contentDescription = "Open preview, ${page.title.ifEmpty { preview.url }}"
          onClick { onCommit(); true }
      })
    }
}