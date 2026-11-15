package com.star.desktop.domain

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking

/**
 * S9: the dialogs show the free space the daemon counts (StarCore's, which on a Mac includes what the system would purge), and fall back to this
 * machine's own count only when the daemon cannot say.
 */
class WorkingLocationFreeSpaceTest {
    @Test fun theDaemonsCountIsTheOneShown() {
        runBlocking { assertEquals(123_456_789L, WorkingLocation.freeBytesAsTheDaemonCountsThem("/anywhere") { 123_456_789L }) }
    }

    @Test fun whenTheDaemonCannotSayThisMachinesCountIsUsed() {
        val here = System.getProperty("java.io.tmpdir")
        assertNotNull(WorkingLocation.freeBytes(here))
        runBlocking {
            assertEquals(WorkingLocation.freeBytes(here)?.let { it / (1 shl 28) }, WorkingLocation.freeBytesAsTheDaemonCountsThem(here) { null }?.let { it / (1 shl 28) })
            // an old daemon answers "unknown method" with an error, which is the same as not saying
            assertNotNull(WorkingLocation.freeBytesAsTheDaemonCountsThem(here) { error("RPC error: unknown method Session.GetFreeSpace") })
        }
    }

    @Test fun aCancelledAskIsNotSwallowed() {
        assertFailsWith<CancellationException> { runBlocking { WorkingLocation.freeBytesAsTheDaemonCountsThem("/x") { throw CancellationException("gone") } } }
    }

    @Test fun theDialogsAskTheDaemon() {
        fun read(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()
        val app = read("star-desktop/src/main/kotlin/com/star/desktop/ui/app/StarApp.kt")
        assertEquals(2, Regex("freeSpace = \\{ vm\\.sessions\\.freeSpace\\(it\\) \\}").findAll(app).count(), "the video import and the sequence location dialogs")
        assertTrue("freeBytesAsTheDaemonCountsThem(effective, freeSpace)" in read("star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/WorkingLocationSection.kt"))
    }
}
