package dev.yab.browser.engine

// Cefrium hosts no extensions; the engine always supplies an empty row list.
data class ExtensionActionRow(val id: String, val extensionId: String, val title: String, val badge: String, val enabled: Boolean)