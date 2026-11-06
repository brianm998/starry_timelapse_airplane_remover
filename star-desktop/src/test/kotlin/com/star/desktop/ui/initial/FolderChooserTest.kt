package com.star.desktop.ui.initial

import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

/** Which dialog the folder choosers use: each platform's own, with Swing's as the fallback. */
class FolderChooserTest {
    private val prop = "apple.awt.fileDialogForDirectories"

    @AfterTest fun cleanUp() { System.clearProperty(prop) }

    private fun recording(result: File?, seen: MutableList<Pair<String?, File?>>): (String, File?) -> File? = { _, start ->
        seen += System.getProperty(prop) to start
        result
    }

    private val unused: (String, File?) -> FolderResult = { _, _ -> error("not this platform's dialog") }

    private fun dialogs(
        mac: (String, File?) -> File?,
        swing: (String, File?) -> File?,
        windows: (String, File?) -> FolderResult = unused,
        linux: (String, File?) -> FolderResult = unused,
    ) = FolderDialogs(mac, windows, linux, swing)

    @Test fun onAMacTheNativeDialogPicksFolders() {
        val dir = Files.createTempDirectory("folderchooser").toFile()
        val picked = File(dir, "sub").apply { mkdirs() }
        try {
            // A chosen folder: the dialog sees the property, the start folder, and the result is the absolute path.
            val native = mutableListOf<Pair<String?, File?>>()
            val swing = mutableListOf<Pair<String?, File?>>()
            val result = chooseDirectory("Mac OS X", "t", dir.absolutePath, dialogs(recording(picked, native), recording(null, swing)))
            assertEquals(picked.absolutePath, result)
            assertEquals(listOf<Pair<String?, File?>>("true" to dir), native)
            assertEquals(emptyList(), swing)
            assertNull(System.getProperty(prop), "restored once the dialog is gone")

            // A cancel returns null and still restores the property, which was set by someone else beforehand.
            System.setProperty(prop, "false")
            assertNull(chooseDirectory("Mac OS X", "t", null, dialogs(recording(null, native), recording(null, swing))))
            assertEquals("false", System.getProperty(prop))
            assertEquals("true" to null, native.last())

            // A start path that is not a folder is not offered to the dialog.
            chooseDirectory("Mac OS X", "t", File(dir, "missing").absolutePath, dialogs(recording(null, native), recording(null, swing)))
            assertNull(native.last().second)

            // A dialog that throws still restores the property.
            assertFailsWith<IllegalStateException> {
                chooseDirectory("Mac OS X", "t", null, dialogs({ _, _ -> throw IllegalStateException("boom") }, recording(null, swing)))
            }
            assertEquals("false", System.getProperty(prop))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun eachPlatformGetsItsPicker() {
        assertEquals(FolderPicker.MAC_PANEL, folderPickerFor("Mac OS X"))
        assertEquals(FolderPicker.WINDOWS_EXPLORER, folderPickerFor("Windows 11"))
        assertEquals(FolderPicker.WINDOWS_EXPLORER, folderPickerFor("Windows 10"))
        assertEquals(FolderPicker.LINUX_NATIVE, folderPickerFor("Linux"))
        assertEquals(FolderPicker.SWING, folderPickerFor("SunOS"))

        // Each OS calls only its own dialog, with the start folder, and returns what it chose.
        val dir = Files.createTempDirectory("folderchooser").toFile()
        val picked = File(dir, "sub").apply { mkdirs() }
        try {
            val calls = mutableListOf<String>()
            val d = FolderDialogs(
                mac = { _, start -> calls += "mac:$start"; picked },
                windows = { _, start -> calls += "windows:$start"; FolderResult.Chosen(picked) },
                linux = { _, start -> calls += "linux:$start"; FolderResult.Chosen(picked) },
                swing = { _, start -> calls += "swing:$start"; picked },
            )
            for ((os, expected) in listOf("Mac OS X" to "mac", "Windows 11" to "windows", "Linux" to "linux", "SunOS" to "swing")) {
                calls.clear()
                assertEquals(picked.absolutePath, chooseDirectory(os, "t", dir.absolutePath, d), os)
                assertEquals(listOf("$expected:$dir"), calls, os)
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun onLinuxWithoutANativeChooserSwingIsUsed() {
        val dir = Files.createTempDirectory("folderchooser").toFile()
        try {
            for (os in listOf("Linux", "Windows 11")) {
                val swing = mutableListOf<Pair<String?, File?>>()
                val native: (String, File?) -> FolderResult = { _, _ -> FolderResult.Unavailable }
                val d = dialogs(mac = { _, _ -> null }, swing = recording(dir, swing), windows = native, linux = native)
                assertEquals(dir.absolutePath, chooseDirectory(os, "t", dir.absolutePath, d), os)
                assertEquals(listOf<Pair<String?, File?>>(null to dir), swing, os)
            }

            // A native dialog that cannot start at all (IOException) is the same as unavailable.
            val swing = mutableListOf<Pair<String?, File?>>()
            val broken: (String, File?) -> FolderResult = { _, _ -> throw java.io.IOException("no zenity") }
            assertEquals(dir.absolutePath, chooseDirectory("Linux", "t", null, dialogs({ _, _ -> null }, recording(dir, swing), linux = broken)))
            assertEquals(1, swing.size)

            // The user cancelling the native dialog is not "unavailable": Swing is not shown on top of it.
            swing.clear()
            val cancelled: (String, File?) -> FolderResult = { _, _ -> FolderResult.Cancelled }
            assertNull(chooseDirectory("Linux", "t", null, dialogs({ _, _ -> null }, recording(dir, swing), linux = cancelled)))
            assertNull(chooseDirectory("Windows 11", "t", null, dialogs({ _, _ -> null }, recording(dir, swing), windows = cancelled)))
            assertEquals(emptyList(), swing)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun helperExitStatusesMapToResults() {
        assertEquals(FolderResult.Chosen(File("/a/b")), folderResultOf(0, "/a/b\n"))
        assertEquals(FolderResult.Cancelled, folderResultOf(1, ""))
        assertEquals(FolderResult.Unavailable, folderResultOf(127, ""))
        assertEquals(FolderResult.Unavailable, folderResultOf(2, "boom"))
    }

    @Test fun helperCommandsCarryTheTitleAndStartFolder() {
        val dir = Files.createTempDirectory("folderchooser").toFile()
        try {
            assertEquals(
                listOf("zenity", "--file-selection", "--directory", "--title=T", "--filename=${dir.absolutePath}/"),
                zenityCommand("T", dir),
            )
            assertEquals(listOf("zenity", "--file-selection", "--directory", "--title=T"), zenityCommand("T", null))
            assertEquals(listOf("kdialog", "--title", "T", "--getexistingdirectory", dir.absolutePath), kdialogCommand("T", dir))
        } finally {
            dir.deleteRecursively()
        }
    }
}
