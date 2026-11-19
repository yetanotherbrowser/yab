package dev.yab.android

import java.io.Closeable
import java.io.InputStream

/**
 * Cefrium has no WebResponse: the forked ViewModel builds this from
 * CefriumBrowser$DownloadItem or an OkHttp fetch, and the controller reads
 * exactly what Gecko's WebResponse used to give it.
 */
interface PageDownloadSource : Closeable {
    val uri: String
    val mime: String?
    /** Negative or absent when the length is unknown or the body is encoded. */
    val size: Long?
    fun stream(timeoutMillis: Long): InputStream?
}