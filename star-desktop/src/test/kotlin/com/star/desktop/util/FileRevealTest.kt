package com.star.desktop.util

import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * What it takes to show a file in the file manager. Opening a real one is the one thing these cannot
 * do, so the JDK and the command runner are given as stand-ins; what is tested is which of them is
 * asked, in what order, and with what, per platform.
 */
class FileRevealTest {

    private val folder = Files.createTempDirectory("FileRevealTest").toFile()
    private val video = File(folder, "night sky-star-v-0_11_5.mp4").apply { writeText("not really a video") }

    @AfterTest
    fun tearDown() {
        folder.deleteRecursively()
    }

    // ---- the platform ----

    @Test
    fun aMacIsAMacWhateverTheJdkCallsIt() {
        assertEquals(FileReveal.Platform.MAC, FileReveal.platform("Mac OS X"))
        // "darwin" contains "win", which is how a check for Windows alone would have taken it
        assertEquals(FileReveal.Platform.MAC, FileReveal.platform("Darwin"))
    }

    @Test
    fun windowsAndEverythingElseAreToldApart() {
        assertEquals(FileReveal.Platform.WINDOWS, FileReveal.platform("Windows 11"))
        assertEquals(FileReveal.Platform.WINDOWS, FileReveal.platform("Windows Server 2022"))
        assertEquals(FileReveal.Platform.OTHER, FileReveal.platform("Linux"))
        assertEquals(FileReveal.Platform.OTHER, FileReveal.platform("FreeBSD"))
        assertEquals(FileReveal.Platform.OTHER, FileReveal.platform(""))
    }

    // ---- the commands, for where the JDK cannot ----

    @Test
    fun aMacRevealsWithOpenDashR() {
        val command = FileReveal.commandFor("Mac OS X", "/Users/me/My Videos/clip.mov")

        assertEquals(listOf("open", "-R", "/Users/me/My Videos/clip.mov"), command?.args)
        assertTrue(command!!.exitStatusMatters)
    }

    /** `/select,` and the path are two arguments, or a path with a space opens the wrong folder. */
    @Test
    fun windowsSelectsTheFileInExplorerWithTheSwitchAndThePathApart() {
        val command = FileReveal.commandFor("Windows 11", "C:\\Users\\me\\My Videos\\clip.mov")

        assertEquals(listOf("explorer.exe", "/select,", "C:\\Users\\me\\My Videos\\clip.mov"), command?.args)
        assertFalse(command!!.exitStatusMatters, "Explorer exits 1 when it has done what it was asked")
    }

    /** xdg-open can open a folder and cannot select a file in it. */
    @Test
    fun otherSystemsOpenTheFolderTheFileIsIn() {
        val command = FileReveal.commandFor("Linux", "/home/me/Videos/clip.mp4")

        assertEquals(listOf("xdg-open", "/home/me/Videos"), command?.args)
        assertTrue(command!!.exitStatusMatters)
    }

    @Test
    fun aPathWithNoFolderGivesOtherSystemsNothingToOpen() {
        assertNull(FileReveal.commandFor("Linux", "clip.mp4"))
    }

    // ---- what is tried, and in what order ----

    private class Stand(val browses: Boolean = false, val runs: Boolean = false) {
        val browsed = mutableListOf<String>()
        val ran = mutableListOf<FileReveal.Command>()
        val browse: (String) -> Boolean = { browsed += it; browses }
        val execute: (FileReveal.Command) -> Boolean = { ran += it; runs }
    }

    @Test
    fun whenTheJdkCanDoItNothingElseIsRun() {
        val stand = Stand(browses = true)

        val shown = FileReveal.reveal(video.path, "Mac OS X", stand.browse, stand.execute)

        assertTrue(shown)
        assertEquals(listOf(video.path), stand.browsed)
        assertTrue(stand.ran.isEmpty(), "the JDK did it, so no command should have been started")
    }

    @Test
    fun whenTheJdkCannotThePlatformsCommandIsRun() {
        val stand = Stand(browses = false, runs = true)

        val shown = FileReveal.reveal(video.path, "Linux", stand.browse, stand.execute)

        assertTrue(shown)
        assertEquals(listOf(listOf("xdg-open", folder.path)), stand.ran.map { it.args })
    }

    @Test
    fun whenNeitherCanItIsNotShown() {
        val stand = Stand(browses = false, runs = false)

        assertFalse(FileReveal.reveal(video.path, "Mac OS X", stand.browse, stand.execute))
        assertEquals(1, stand.ran.size, "the command was tried before giving up")
    }

    /** A video that has been moved or deleted since it was rendered is not one to show. */
    @Test
    fun aFileThatIsNotThereIsNotRevealedAndNothingIsTried() {
        val gone = File(folder, "gone.mp4")
        val stand = Stand(browses = true, runs = true)

        assertFalse(FileReveal.reveal(gone.path, "Mac OS X", stand.browse, stand.execute))
        assertTrue(stand.browsed.isEmpty() && stand.ran.isEmpty())
    }
}
