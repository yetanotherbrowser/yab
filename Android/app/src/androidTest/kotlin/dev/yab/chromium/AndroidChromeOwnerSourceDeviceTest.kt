package dev.yab.chromium

import android.content.Context
import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.sync.AndroidSyncBridge
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.io.File
import java.util.UUID

class AndroidChromeOwnerSourceDeviceTest {
    private val target get() = InstrumentationRegistry.getInstrumentation().targetContext

    private class IsolatedContext(base: Context) : ContextWrapper(base), Closeable {
        private val identifier = UUID.randomUUID().toString().replace("-", "")
        private val root = File(base.cacheDir, "chrome-owner-test-$identifier").apply { check(mkdirs()) }
        override fun getApplicationContext(): Context = this
        override fun getNoBackupFilesDir(): File = File(root, "no-backup").apply { mkdirs() }
        override fun getFilesDir(): File = File(root, "files").apply { mkdirs() }
        override fun getCacheDir(): File = File(root, "cache").apply { mkdirs() }
        override fun close() { root.deleteRecursively() }
    }

    @Test(timeout = 30_000)
    fun prepareReadsTheOffStateWithoutLoginAndRegistryLocksItsOwnFile() {
        IsolatedContext(target).use { context ->
            val bridge = AndroidSyncBridge(context, "https://127.0.0.1:1", allowInsecureForTests = true)
            try {
                val source = runBlocking { AndroidChromeOwnerSource.prepare(bridge) }
                // A never-paired bridge maps to the off state: standalone only, and a live reader.
                val ownership = source.current()
                assertEquals(null, ownership.account); assertEquals(null, ownership.device)
                assertTrue(ownership.permits(ChromeOwnerSource.StandaloneLocal))
                assertEquals(ownership, AndroidChromeOwnerSource.ownershipOf(bridge))
                // The registry is its own file under noBackupFilesDir; opening it takes the writer lock.
                val registryFile = File(context.noBackupFilesDir, "ChromeNative/identities.json")
                AndroidChromeOwnerSource.registry(context).use { registry ->
                    assertTrue(registryFile.isFile)
                    val owner = registry.beginNewOwner(ChromeOwnerSource.StandaloneLocal)
                    assertEquals(owner, registry.savedOwner(ChromeOwnerSource.StandaloneLocal))
                }
            } finally { bridge.close() }
        }
    }
}