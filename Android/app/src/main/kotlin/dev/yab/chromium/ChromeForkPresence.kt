package dev.yab.chromium

import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.util.function.BooleanSupplier

/**
 * The Chromium fork's bootstrap class, linked but never initialized here:
 * the lookup runs with initialize=false, so resolving presence never runs
 * the fork's static state or native loader. The producer's activation
 * barrier owns when the fork's bootstrap first executes.
 *
 * A missing fork is ClassNotFoundException; a fork whose native dependency
 * is absent fails linkage (NoClassDefFoundError extends LinkageError). Both
 * mean "not present on this build" and resolve to null, never a startup
 * crash. Anything else a verifier throws still propagates: it is not a
 * presence signal and hiding it would mask a real error.
 */
class ChromeForkPresence private constructor(internal val bootstrapClass: Class<*>) {
    companion object {
        /** The fork APK's bootstrap entry point; the only org.chromium name the app may reference. */
        internal const val BOOTSTRAP_CLASS_NAME = "org.chromium.chrome.browser.yab.YabChromeBootstrap"

        fun resolve(verifier: (String) -> Class<*> = ::linkBootstrap): ChromeForkPresence? =
            try { ChromeForkPresence(verifier(BOOTSTRAP_CLASS_NAME)) }
            catch (_: ClassNotFoundException) { null }
            catch (_: LinkageError) { null }

        internal fun linkBootstrap(name: String): Class<*> =
            Class.forName(name, false, ChromeForkPresence::class.java.classLoader)
    }
}

/**
 * [ChromeBootstrapPort] over the fork's YabChromeBootstrap statics. The app
 * never compiles against the fork (the fork APK is a separate build), so the
 * four methods bind by reflection when the port is constructed.
 *
 * Drift contract: construction happens only after the producer's activation
 * barrier accepted the owner, so a fork that drifted from the reviewed
 * signatures must fail here as a loud [NoSuchMethodException], never as a
 * silent missing call that would leave the barrier passed and native work
 * undone.
 */
class YabChromeBootstrapPort(presence: ChromeForkPresence) : ChromeBootstrapPort {
    private val activateSaved: Method = presence.bootstrapClass
        .getMethod("activateSavedOwner", String::class.java, String::class.java, BooleanSupplier::class.java)
    private val startNew: Method = presence.bootstrapClass
        .getMethod("startNewOwner", String::class.java, String::class.java, BooleanSupplier::class.java)
    private val revoke: Method = presence.bootstrapClass.getMethod("revokeOwner")
    private val release: Method = presence.bootstrapClass.getMethod("releaseAfterTeardown")

    override fun activateSavedOwner(accountUUID: String, expectedOwnerEpochUUID: String, lease: BooleanSupplier): Boolean =
        invoke(activateSaved, accountUUID, expectedOwnerEpochUUID, lease) as Boolean

    override fun startNewOwner(accountUUID: String, ownerEpochUUID: String, lease: BooleanSupplier) {
        invoke(startNew, accountUUID, ownerEpochUUID, lease)
    }

    override fun revokeOwner() { invoke(revoke) }
    override fun releaseAfterTeardown() { invoke(release) }

    private fun invoke(method: Method, vararg arguments: Any?): Any? =
        try { method.invoke(null, *arguments) }
        // The producer's catch would otherwise report reflection plumbing instead of the fork's own failure.
        catch (invocation: InvocationTargetException) { throw unwrap(invocation) }
}

/** Reflection wraps the callee's throw in InvocationTargetException; the caller must see the fork's own exception. */
internal fun unwrap(invocation: InvocationTargetException): Throwable = invocation.cause ?: invocation