package dev.yab.browser.engine

import com.cefrium.CefriumBrowser
import com.cefrium.CefriumNavigationClient
import com.cefrium.CefriumNavigationRequest
import com.cefrium.CefriumProfile
import java.io.Closeable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Peek preview over Cefrium: the SDK's browser ctor runs without a surface,
 * so a background browser can render the link the way Gecko's hidden
 * GeckoSession did. Never a browser tab; closed with the menu.
 */
class CefriumLinkPreview internal constructor(
    val id: String,
    val sourceTab: String,
    val url: String,
    val isPrivate: Boolean,
    profile: CefriumProfile,
    sourceCurrent: () -> Boolean,
    private val invalidated: () -> Unit,
) : Closeable {
    val session: CefriumBrowser = CefriumBrowser(1, 1, 1f, profile)
    private val lease = LinkPreviewLease(sourceCurrent)
    private val mutablePage = MutableStateFlow(LinkPreviewPage())
    val page = mutablePage.asStateFlow()
    private var closed = false

    init {
        session.setPageVisible(false)
        session.setNavigationClient(object : CefriumNavigationClient {
            override fun onLoadStart(browser: CefriumBrowser, url: String) {
                if (current()) mutablePage.value = LinkPreviewPage()
            }
            override fun onLoadingStateChanged(browser: CefriumBrowser, isLoading: Boolean, canGoBack: Boolean, canGoForward: Boolean) {
                if (!isLoading && current()) mutablePage.value = mutablePage.value.copy(loading = false)
            }
            override fun onLoadError(browser: CefriumBrowser, error: com.cefrium.CefriumLoadError) {
                if (current()) mutablePage.value = mutablePage.value.copy(loading = false, failed = true)
            }
            override fun onRenderProcessTerminated(browser: CefriumBrowser, status: com.cefrium.CefriumRendererTerminationStatus, errorCode: Int) {
                if (!closed) invalidated()
            }
            override fun onBeforeNavigate(browser: CefriumBrowser, request: CefriumNavigationRequest): Boolean =
                !(current() && linkPreviewWebUrl(request.url))
        })
        session.setOnTitleChangedListener { title ->
            if (current()) mutablePage.value = mutablePage.value.copy(title = title.orEmpty())
        }
        session.setOnFullscreenChangedListener { enabled ->
            if (enabled) runCatching { session.exitFullscreen() }
        }
        runCatching { session.loadUrl(url) }
            .onFailure { close() }
    }

    fun current(): Boolean = lease.current() && !closed
    fun consume(): Boolean = current().also { live -> lease.consume() }
    override fun close() {
        if (closed) return
        closed = true
        lease.close()
        runCatching { session.setPageVisible(false) }
        runCatching { session.close() }
    }
}