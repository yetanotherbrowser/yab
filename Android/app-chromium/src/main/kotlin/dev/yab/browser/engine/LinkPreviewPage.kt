package dev.yab.browser.engine

/**
 * :app defines this in NativeLinkPreview.kt, which the Chromium build
 * excludes; CefriumLinkPreview and the card counterpart still need it.
 */
data class LinkPreviewPage(val title: String = "", val loading: Boolean = true, val failed: Boolean = false)