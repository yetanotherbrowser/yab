package dev.yab.chromium

import dev.yab.shield.ShieldPolicy
import dev.yab.shield.ShieldRules

/**
 * The fork-presence seam for ad blocking. The unapplied Chromium fork's
 * request-path enforcer implements this port on its required UI thread,
 * after the owner lifecycle is active: Cromite keeps the engine inside the
 * fork (eyeo ABP core; Bromite used subresource_filter) and feeds it lists
 * from the app, never the other way around.
 *
 * Configure replaces the whole ruleset and the per-site policy atomically:
 * half-applied state must not survive a failure, so a throwing configure
 * leaves the previous ruleset enforcing.
 */
interface ChromeAdblockPort {
    /** False refuses the ruleset (too large, malformed) and keeps the previous one. */
    fun configure(rules: ShieldRules, policy: ShieldPolicy): Boolean
    /** Apply a per-site choice to the live ruleset; the ruleset bytes stay unchanged. */
    fun sitePolicyChanged(policy: ShieldPolicy)
}

/** One configured state: the selected rules and the policy the fork must enforce. */
data class ChromeAdblockState(val rules: ShieldRules, val policy: ShieldPolicy)

/**
 * Application-scoped holder of the adblock seam, twin of [ChromeEngineHost]:
 * every call runs the main-thread gate first, then the port. [current] reports
 * the last state the fork acknowledged, so a refused configure never reads as
 * applied.
 */
class ChromeAdblockHost internal constructor(
    private val port: ChromeAdblockPort,
    private val mainThreadGate: () -> Unit,
) {
    private var configured: ChromeAdblockState? = null

    fun configure(rules: ShieldRules, policy: ShieldPolicy): Boolean {
        mainThreadGate()
        val accepted = port.configure(rules, policy)
        if (accepted) configured = ChromeAdblockState(rules, policy)
        return accepted
    }

    fun sitePolicyChanged(policy: ShieldPolicy) {
        mainThreadGate()
        port.sitePolicyChanged(policy)
    }

    /** The state the fork acknowledged last; null before the first accepted configure. */
    fun current(): ChromeAdblockState? {
        mainThreadGate()
        return configured
    }
}