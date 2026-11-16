package dev.yab.chromium

import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.WebsiteProfile
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.function.BooleanSupplier

/** One capture from native Sync ownership, not from independent account/records UI flows. */
data class ChromeSyncOwnership(
    val account: String?, val device: String?, val epoch: Long, val available: Boolean,
) {
    internal fun permits(source: ChromeOwnerSource) = available && when (source) {
        ChromeOwnerSource.StandaloneLocal -> account == null && device == null
        is ChromeOwnerSource.Paired -> account == source.account && !device.isNullOrEmpty()
    }
}

/** The unapplied Chromium fork's bootstrap implements this port on its required UI thread. */
interface ChromeBootstrapPort {
    fun activateSavedOwner(accountUUID: String, expectedOwnerEpochUUID: String, lease: BooleanSupplier): Boolean
    fun startNewOwner(accountUUID: String, ownerEpochUUID: String, lease: BooleanSupplier)
    fun revokeOwner()
    /** The caller confirms all Chrome Tabs/WebContents/Profile resources were disposed first. */
    fun releaseAfterTeardown()
}

enum class ChromeOwnerStart { SAVED, EXPLICIT_NEW }

class ChromeOwnerActivation internal constructor(
    val identity: ChromeOwnerIdentity,
    val start: ChromeOwnerStart,
    internal val captured: ChromeSyncOwnership,
    private val currentOwnership: () -> ChromeSyncOwnership,
    private val belongsToProducer: () -> Boolean,
) {
    internal val revoked = AtomicBoolean(false)
    // Read by lease callbacks and teardown paths on Chromium's UI thread while
    // transitions happen under the producer monitor. Volatile keeps those reads honest.
    @Volatile internal var port: ChromeBootstrapPort? = null
    @Volatile internal var activated = false
    @Volatile internal var privateGeneration = 0L
    internal val privateProfiles = mutableMapOf<String, String>()
    internal val privateTabs = mutableMapOf<String, String>()
    val lease = BooleanSupplier {
        val valid = try { belongsToProducer() && currentOwnership() == captured && captured.permits(identity.source) }
        catch (_: Exception) { false }
        if (!valid) revoked.set(true)
        !revoked.get()
    }
}

class ChromeTabActivation internal constructor(
    val identity: ChromeNamespaceIdentity,
    val lease: BooleanSupplier,
)

/**
 * Prepares stable native IDs before ChromeActivity/Profile initialization. No Chrome int IDs,
 * cookies, seals, restored owner snapshot, or Sync credentials are read/written here.
 * Registry preparation is IO; activate/revoke/release calls run on Chromium's UI thread.
 *
 * Threading contract: this monitor is the single enforcement point of the one-active-owner
 * invariant, so every mutating call (prepare*, activate, revoke, ownershipChanged, tab,
 * privateTabsDisposed, releaseAfterTeardown) is @Synchronized and must run on Chromium's UI
 * thread, while lease callbacks and ownershipChanged re-checks may fire from native or Sync
 * threads. Port calls and registry IO happen under the monitor on purpose: the window where a
 * revoked owner could reach the native port must not exist, and fail-stuck (a blocked caller)
 * is preferred over fail-corrupt (a revoked owner activating native resources). Callers must
 * never await this monitor from Android's main thread while native teardown runs elsewhere.
 *
 * The activation barrier gates only the Chrome engine, never Yab's process launch: when the
 * Sync lease is unavailable at cold start, activate returns false and the caller must show
 * Yab's own UI instead of starting a new Chrome owner; no automatic startNewOwner fallback.
 */
class ChromeOwnerProducer(
    private val registry: ChromeIdentityRegistry,
    private val currentOwnership: () -> ChromeSyncOwnership,
) {
    private val active = AtomicReference<ChromeOwnerActivation?>(null)

    @Synchronized fun prepareSaved(source: ChromeOwnerSource): ChromeOwnerActivation? {
        check(active.get() == null) { "Previous Chrome owner has not completed teardown" }
        val capture = capture(source)
        val saved = registry.savedOwner(source) ?: return null
        check(currentOwnership() == capture) { "Sync ownership changed while reading local identities" }
        return prepare(saved, ChromeOwnerStart.SAVED, capture)
    }

    /** Explicit user/native operation. Never call automatically after activateSavedOwner returns false. */
    @Synchronized fun prepareNew(source: ChromeOwnerSource): ChromeOwnerActivation {
        check(active.get() == null) { "Previous Chrome owner has not completed teardown" }
        val capture = capture(source)
        val owner = registry.beginNewOwner(source)
        check(currentOwnership() == capture) { "Sync ownership changed while saving local identities" }
        return prepare(owner, ChromeOwnerStart.EXPLICIT_NEW, capture)
    }

    private fun capture(source: ChromeOwnerSource) = currentOwnership().also {
        check(it.permits(source)) { "Native Sync ownership does not match this local Chrome owner" }
    }
    private fun prepare(identity: ChromeOwnerIdentity, start: ChromeOwnerStart, capture: ChromeSyncOwnership): ChromeOwnerActivation {
        lateinit var prepared: ChromeOwnerActivation
        prepared = ChromeOwnerActivation(identity, start, capture, currentOwnership) { active.get() === prepared }
        active.set(prepared)
        return prepared
    }

    /**
     * True is the startup barrier for the Chrome engine alone; Yab's own launch never waits on it.
     * Two refusal exits: a lease failure before native acceptance discards the ticket entirely
     * (active cleared, no native work was done), while a failure after acceptance keeps the
     * ticket current with a revoked lease and a revokeOwner() already sent, so the caller must
     * finish native teardown and call releaseAfterTeardown. Never call this again on refusal.
     */
    @Synchronized fun activate(owner: ChromeOwnerActivation, port: ChromeBootstrapPort): Boolean {
        check(active.get() === owner && owner.port == null && !owner.activated) { "This prepared Chrome owner is not current, already activated or already released" }
        if (!owner.lease.getAsBoolean()) { active.set(null); return false }
        owner.port = port
        try {
            val accepted = when (owner.start) {
                ChromeOwnerStart.SAVED -> port.activateSavedOwner(owner.identity.accountUUID, owner.identity.ownerEpochUUID, owner.lease)
                ChromeOwnerStart.EXPLICIT_NEW -> {
                    port.startNewOwner(owner.identity.accountUUID, owner.identity.ownerEpochUUID, owner.lease); true
                }
            }
            if (!accepted) {
                owner.revoked.set(true); owner.port = null; active.set(null)
                return false
            }
            owner.activated = true
            if (!owner.lease.getAsBoolean()) { port.revokeOwner(); return false }
            return true
        } catch (error: Exception) {
            // A throwing native call might have installed resources. Preserve teardown ownership.
            owner.revoked.set(true)
            try { port.revokeOwner() } catch (cleanup: Exception) { error.addSuppressed(cleanup) }
            throw error
        }
    }

    /** Bind this to the atomic accountRecords lifecycle collector on Chromium's UI dispatcher. */
    @Synchronized fun ownershipChanged() {
        val owner = active.get() ?: return
        if (!owner.lease.getAsBoolean()) revoke(owner)
    }

    /** Revoke before hiding/locking/switching owner, then close actual native resources. */
    @Synchronized fun revoke(owner: ChromeOwnerActivation) {
        check(active.get() === owner)
        owner.revoked.set(true)
        invalidatePrivate(owner)
        owner.port?.revokeOwner()
    }

    /** Required after confirmed native destruction; a request-to-close is insufficient. */
    @Synchronized fun releaseAfterTeardown(owner: ChromeOwnerActivation) {
        check(active.get() === owner && owner.revoked.get()) { "Chrome owner must be revoked before native teardown" }
        owner.port?.releaseAfterTeardown()
        invalidatePrivate(owner)
        active.set(null)
    }

    /** A prepared ticket that never reached native activation can be cancelled without native teardown. */
    @Synchronized fun cancelPrepared(owner: ChromeOwnerActivation) {
        check(active.get() === owner && owner.port == null && !owner.activated)
        owner.revoked.set(true); invalidatePrivate(owner); active.set(null)
    }

    /** Captured browser source must still own the same native tab/profile before and after IO. */
    @Synchronized fun tab(
        owner: ChromeOwnerActivation, tab: BrowserTab, profile: WebsiteProfile, sourceCurrent: BooleanSupplier,
    ): ChromeTabActivation {
        check(active.get() === owner && owner.activated && owner.lease.getAsBoolean() && sourceCurrent.getAsBoolean())
        require(tab.isPrivate == profile.isPrivate) { "Private tab and native website profile disagree" }
        boundedIdentifier(tab.id); boundedIdentifier(profile.id)
        val privateGeneration = owner.privateGeneration
        val identity = if (tab.isPrivate) {
            check(owner.privateProfiles.size < CHROME_MAX_PROFILES_PER_OWNER || profile.id in owner.privateProfiles)
            check(owner.privateTabs.size < CHROME_MAX_TABS_PER_OWNER || tab.id in owner.privateTabs)
            ChromeNamespaceIdentity(owner.identity.accountUUID,
                owner.privateTabs.getOrPut(tab.id) { UUID.randomUUID().toString() },
                owner.privateProfiles.getOrPut(profile.id) { UUID.randomUUID().toString() }, inMemory = true, privateMode = true)
        } else registry.publicIdentity(owner.identity, profile.id, tab.id)
        check(owner.lease.getAsBoolean() && sourceCurrent.getAsBoolean()) { "Native tab source changed while mapping its identity" }
        val revoked = AtomicBoolean(false)
        val lease = BooleanSupplier {
            val current = try { owner.lease.getAsBoolean() && sourceCurrent.getAsBoolean() && (!identity.privateMode || owner.privateGeneration == privateGeneration) }
            catch (_: Exception) { false }
            if (!current) revoked.set(true)
            !revoked.get()
        }
        return ChromeTabActivation(identity, lease)
    }

    /** Call only after native Private tabs are disposed. New Private IDs are RAM-only and fresh. */
    @Synchronized fun privateTabsDisposed(owner: ChromeOwnerActivation) {
        check(active.get() === owner)
        invalidatePrivate(owner)
    }
    private fun invalidatePrivate(owner: ChromeOwnerActivation) {
        owner.privateGeneration++
        owner.privateProfiles.clear(); owner.privateTabs.clear()
    }
}
