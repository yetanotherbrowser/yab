package dev.yab.shield

import android.content.Context
import com.cefrium.Cefrium
import com.cefrium.CefriumBrowser
import java.io.Closeable
import java.io.File
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class ShieldStatus(val ready: Boolean = false, val rules: Int = 0, val skipped: Int = 0, val left: Int = 0,
    val unsupportedPopupRules: Int = 0, val refreshing: Boolean = false, val sources: List<ShieldListState> = emptyList(), val error: String? = null)

/**
 * Cefrium's adblock is a native list plus per-browser and per-profile toggles,
 * not a rule matcher the app can query, so counts stay at their defaults.
 */
class ShieldRuntime(private val context: Context) : Closeable {
    private var closed = false
    private val failure = MutableStateFlow<String?>(null)
    val errors = failure.asStateFlow()

    /** The engine keeps one list for every browser; the count is Cefrium's own rule total. */
    fun refreshList(callback: Cefrium.AdBlockListCallback? = null) {
        check(!closed) { "Shield is closed" }
        Cefrium.downloadAndLoadEasyList(context, callback)
    }

    override fun close() { closed = true; failure.value = null }

    companion object {
        /** Cefrium ships no popup-blocking matcher; Gecko's shield was the popup authority. */
        fun allowsPopup(request: ShieldPopupRequest): Boolean = true
    }
}

/** Retained with the browser, so Private site choices never enter a disk snapshot. */
class ShieldController(context: Context, private val scope: CoroutineScope,
    val policies: ShieldPolicyStore = ShieldPolicyStore(File(context.filesDir, "shield-policy.json")),
    private val automaticDownloads: Boolean = true) : Closeable {
    private val app = context.applicationContext
    private val native = ShieldRuntime(app)
    private val mutable = MutableStateFlow(ShieldStatus())
    val state = mutable.asStateFlow()
    private val mutex = Mutex()
    private var closed = false
    private var visible = false
    private var automaticRefresh: Job? = null
    private var listError: String? = null

    /**
     * The policy store stays the single source of truth; the engine's browsers
     * consult the policy collector instead of a background matcher, so the
     * apply step is a no-op on the controller side.
     */
    private val job = scope.launch {
        launch { native.errors.filterNotNull().collect { mutable.value = mutable.value.copy(ready = false, error = it) } }
    }

    init {
        // Gecko clears the banner at construction from bundled asset rules; Cefrium's
        // native list applies as soon as the call below starts, so ready flips here
        // and only a real download failure sets it back.
        mutable.value = mutable.value.copy(ready = true)
        native.refreshList(Cefrium.AdBlockListCallback { _, error ->
            // Cefrium passes a null error string on success; it is a Java platform type here.
            if (!error.isNullOrBlank()) mutable.value = mutable.value.copy(ready = false, error = error)
        })
    }

    fun foreground() {
        if (closed || visible || !automaticDownloads) return
        visible = true
        automaticRefresh = scope.launch { delay(30_000); refresh() }
    }

    fun background() { visible = false; automaticRefresh?.cancel(); automaticRefresh = null }

    /** Cefrium ships no popup-blocking matcher; every popup follows the page's own choice. */
    fun checkPopup(request: ShieldPopupRequest): Boolean = ShieldRuntime.allowsPopup(request)

    /** The store gate survives; the engine applies the choice per browser on reload. */
    suspend fun setSite(host: String?, privately: Boolean, enabled: Boolean): Boolean {
        policies.setSite(host, privately, enabled)
        val expected = policies.state.value
        return !closed && policies.state.value == expected
    }

    /** Kept for parity: the list refresh only refreshes Cefrium's native EasyList copy. */
    suspend fun refresh(explicit: Boolean = false) = mutex.withLock {
        if (closed || !explicit && !policies.state.value.global) return@withLock
        mutable.value = mutable.value.copy(refreshing = true)
        try {
            val done = CompletableDeferred<Unit>()
            withContext(Dispatchers.Main) {
                native.refreshList(Cefrium.AdBlockListCallback { count, error ->
                    // Same platform-type null as the constructor callback: null means success.
                    listError = error?.takeIf { it.isNotBlank() }
                    mutable.value = mutable.value.copy(ready = error.isNullOrBlank(),
                        // Cefrium reports one loaded-rule total, not the app's selected/skipped split.
                        rules = if (error.isNullOrBlank()) count else 0, error = listError)
                    done.complete(Unit)
                })
            }
            withTimeoutOrNull(60_000) { done.await() }
        } finally { mutable.value = mutable.value.copy(refreshing = false) }
    }

    override fun close() { closed = true; background(); job.cancel(); native.close() }

    companion object {
        /**
         * Cefrium has one process-wide adblock list and one toggle per browser
         * or profile. Public site exceptions are exact hosts on the profile;
         * a site disabled only in Private stays enabled in public because the
         * two profiles cannot share an exception set.
         */
        fun applyToBrowser(browser: CefriumBrowser, policy: ShieldPolicy, urlHost: String?): Boolean {
            val profile = browser.profile
            val siteEnabled = policy.enabled(urlHost, profile.isIncognito)
            browser.setAdBlockEnabled(policy.global && siteEnabled)
            val disabled = (if (profile.isIncognito) policy.privateSites else policy.publicSites)
                .filterValues { !it }.keys
            return profile.setAdBlockExceptions(disabled)
        }
    }
}
