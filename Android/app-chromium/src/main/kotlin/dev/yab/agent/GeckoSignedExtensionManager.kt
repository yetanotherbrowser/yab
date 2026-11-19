package dev.yab.agent

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

// Cefrium hosts no signed WebExtensions, so the Chromium edition has no
// installable-extension engine: the shared screen stays reachable but empty.

data class InstalledAndroidExtension(val id: String, val name: String, val version: String, val enabled: Boolean, val optionsUrl: String?)
data class ExtensionConsent(val token: String, val name: String, val permissions: List<String>, val origins: List<String>, val dataCollection: List<String>)
data class AndroidExtensionState(val installed: List<InstalledAndroidExtension> = emptyList(), val consent: ExtensionConsent? = null, val busy: Boolean = false, val error: String? = null)

class GeckoSignedExtensionManager(
    context: Context,
    private val privateContext: () -> Boolean = { false },
) {
    val state: StateFlow<AndroidExtensionState> = MutableStateFlow(AndroidExtensionState())

    suspend fun install(uri: Uri) {}
    fun installHttps(address: String) {}
    fun setEnabled(id: String, enabled: Boolean) {}
    fun remove(id: String) {}
    fun resolveConsent(token: String, allow: Boolean) {}
    fun clearError() {}
    fun cancelPendingConsent() {}
    fun refresh() {}
    fun close() {}
}