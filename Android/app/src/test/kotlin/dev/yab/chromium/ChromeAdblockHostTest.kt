package dev.yab.chromium

import dev.yab.shield.ShieldPolicy
import dev.yab.shield.ShieldRule
import dev.yab.shield.ShieldRules
import org.junit.Assert.*
import org.junit.Test

class ChromeAdblockHostTest {
    private class Port : ChromeAdblockPort {
        var configureCalls = 0; var policyCalls = 0
        var accept = true
        var throwing = false
        var lastRules: ShieldRules? = null; var lastPolicy: ShieldPolicy? = null
        override fun configure(rules: ShieldRules, policy: ShieldPolicy): Boolean {
            configureCalls++
            if (throwing) throw IllegalStateException("fork rejected the ruleset")
            lastRules = rules; lastPolicy = policy
            return accept
        }
        override fun sitePolicyChanged(policy: ShieldPolicy) { policyCalls++; lastPolicy = policy }
    }

    private fun rules(blocks: Int) = ShieldRules(blocks = List(blocks) { index -> ShieldRule("block", "ads$index.example") })
    private val policy = ShieldPolicy()
    private val paused = ShieldPolicy(publicSites = mapOf("example.com" to false))

    @Test fun everyCallRunsTheMainThreadGateBeforeThePort() {
        val port = Port()
        var gateCalls = 0
        val host = ChromeAdblockHost(port) { gateCalls++ }
        host.configure(rules(2), policy)
        assertEquals(1, gateCalls)
        host.sitePolicyChanged(paused)
        assertEquals(2, gateCalls)
        host.current()
        assertEquals(3, gateCalls)
        assertEquals(1, port.configureCalls)
        assertEquals(1, port.policyCalls)
    }

    @Test fun refusedConfigureKeepsThePreviousAcknowledgedState() {
        val port = Port()
        val host = ChromeAdblockHost(port) {}
        val first = rules(1)
        assertTrue(host.configure(first, policy))
        port.accept = false
        val second = rules(2)
        assertFalse(host.configure(second, paused))
        // The fork kept the first ruleset; the holder must not report the refused one.
        val current = host.current()!!
        assertSame(first, current.rules)
        assertEquals(policy, current.policy)
        assertEquals(2, port.configureCalls)
    }

    @Test fun throwingConfigureLeavesThePortStateUntouchedAndTheHolderBackward() {
        val port = Port()
        val host = ChromeAdblockHost(port) {}
        val first = rules(1)
        assertTrue(host.configure(first, policy))
        port.throwing = true
        assertThrows(IllegalStateException::class.java) { host.configure(rules(3), paused) }
        assertSame(first, host.current()!!.rules)
        // A throwing configure must not have half-installed the new policy.
        assertEquals(policy, port.lastPolicy)
    }

    @Test fun gateRefusalBlocksThePortBeforeAnyWork() {
        val port = Port()
        val host = ChromeAdblockHost(port) { throw IllegalStateException("off Chromium UI thread") }
        assertThrows(IllegalStateException::class.java) { host.configure(rules(1), policy) }
        assertEquals(0, port.configureCalls)
        assertThrows(IllegalStateException::class.java) { host.sitePolicyChanged(policy) }
        assertEquals(0, port.policyCalls)
        // The read gates too: no acknowledged state escapes off the main thread.
        assertThrows(IllegalStateException::class.java) { host.current() }
    }

    @Test fun sitePolicyChangeReachesThePortWithoutTouchingTheRuleset() {
        val port = Port()
        val host = ChromeAdblockHost(port) {}
        val rules = rules(1)
        host.configure(rules, policy)
        host.sitePolicyChanged(paused)
        assertEquals(paused, port.lastPolicy)
        assertSame(rules, port.lastRules)
        // The holder's acknowledged state keeps the configure-time policy; the
        // live policy is the fork's business until a configure carries it again.
        assertEquals(policy, host.current()!!.policy)
    }
}