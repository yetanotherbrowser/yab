package dev.yab.chromium

import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.WebsiteProfile
import java.util.function.BooleanSupplier

/**
 * The seam's first consumer: application-scoped holder of the Chrome owner
 * lifecycle. Every call must arrive from Chromium's UI thread (Android's
 * main Looper under the fork process model); [mainThreadGate] enforces that
 * before the producer monitor is touched, because port calls and registry
 * IO run under that monitor and any other thread would block it fail-stuck.
 *
 * The port factory is the fork-presence seam: [activate] reaches it only
 * after the lease survives its pre-native check, matching the producer's
 * contract that a refused activation never touches the native port.
 */
class ChromeEngineHost internal constructor(
    private val producer: ChromeOwnerProducer,
    private val portFactory: () -> ChromeBootstrapPort,
    private val mainThreadGate: () -> Unit,
) {
    fun prepareSaved(source: ChromeOwnerSource): ChromeOwnerActivation? {
        mainThreadGate()
        return producer.prepareSaved(source)
    }

    /** Explicit user/native operation. Never call automatically after activate returned false. */
    fun prepareNew(source: ChromeOwnerSource): ChromeOwnerActivation {
        mainThreadGate()
        return producer.prepareNew(source)
    }

    fun activate(owner: ChromeOwnerActivation): Boolean {
        mainThreadGate()
        return producer.activate(owner, portFactory())
    }

    fun ownershipChanged() {
        mainThreadGate()
        producer.ownershipChanged()
    }

    fun revoke(owner: ChromeOwnerActivation) {
        mainThreadGate()
        producer.revoke(owner)
    }

    fun releaseAfterTeardown(owner: ChromeOwnerActivation) {
        mainThreadGate()
        producer.releaseAfterTeardown(owner)
    }

    /** A prepared ticket that never reached native activation can be cancelled without native teardown. */
    fun cancelPrepared(owner: ChromeOwnerActivation) {
        mainThreadGate()
        producer.cancelPrepared(owner)
    }

    fun tab(
        owner: ChromeOwnerActivation, tab: BrowserTab, profile: WebsiteProfile, sourceCurrent: BooleanSupplier,
    ): ChromeTabActivation {
        mainThreadGate()
        return producer.tab(owner, tab, profile, sourceCurrent)
    }

    fun privateTabsDisposed(owner: ChromeOwnerActivation) {
        mainThreadGate()
        producer.privateTabsDisposed(owner)
    }

    companion object {
        fun create(
            registry: ChromeIdentityRegistry,
            ownership: () -> ChromeSyncOwnership,
            portFactory: () -> ChromeBootstrapPort,
            mainThreadGate: () -> Unit,
        ): ChromeEngineHost = ChromeEngineHost(ChromeOwnerProducer(registry, ownership), portFactory, mainThreadGate)
    }
}