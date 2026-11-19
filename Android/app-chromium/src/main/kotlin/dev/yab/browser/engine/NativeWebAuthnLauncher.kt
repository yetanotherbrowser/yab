package dev.yab.browser.engine

// Cefrium's WebAuthn bridge is a process-wide registrar, not a per-session activity delegate.
object NativeWebAuthnLauncher {
    fun attach() {
        com.cefrium.webauthn.CefAuthenticatorInterfaceRegistrar.register()
    }
}