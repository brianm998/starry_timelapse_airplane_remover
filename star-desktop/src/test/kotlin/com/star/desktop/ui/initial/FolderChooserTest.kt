package com.star.desktop.ui.initial

import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

/** Which dialog the folder choosers use: the native Finder panel on a Mac, Swing's elsewhere. */
class FolderChooserTest {
    private val prop = "apple.awt.fileDialogForDirectories"

    @AfterTest fun cleanUp() { System.clearProperty(prop) }

    private fun recording(result: File?, seen: MutableList<Pair<String?, File?>>): (String, File?) -> File? = { _, start ->
        seen += System.getProperty(prop) to start
        result
    }

    @Test fun onAMacTheNativeDialogPicksFolders() {
        val dir = Files.createTempDirectory("folderchooser").toFile()
        val picked = File(dir, "sub").apply { mkdirs() }
        try {
            // A chosen folder: the dialog sees the property, the start folder, and the result is the absolute path.
            val native = mutableListOf<Pair<String?, File?>>()
            val swing = mutableListOf<Pair<String?, File?>>()
            val result = chooseDirectory("Mac OS X", "t", dir.absolutePath, recording(picked, native), recording(null, swing))
            assertEquals(picked.absolutePath, result)
            assertEquals(listOf<Pair<String?, File?>>("true" to dir), native)
            assertEquals(emptyList(), swing)
            assertNull(System.getProperty(prop), "restored once the dialog is gone")

            // A cancel returns null and still restores the property, which was set by someone else beforehand.
            System.setProperty(prop, "false")
            assertNull(chooseDirectory("Mac OS X", "t", null, recording(null, native), recording(null, swing)))
            assertEquals("false", System.getProperty(prop))
            assertEquals("true" to null, native.last())

            // A start path that is not a folder is not offered to the dialog.
            chooseDirectory("Mac OS X", "t", File(dir, "missing").absolutePath, recording(null, native), recording(null, swing))
            assertNull(native.last().second)

            // A dialog that throws still restores the property.
            assertFailsWith<IllegalStateException> {
                chooseDirectory("Mac OS X", "t", null, { _, _ -> throw IllegalStateException("boom") }, recording(null, swing))
            }
            assertEquals("false", System.getProperty(prop))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun elsewhereTheSwingChooserStays() {
        val dir = Files.createTempDirectory("folderchooser").toFile()
        try {
            for (os in listOf("Windows 11", "Linux")) {
                val native = mutableListOf<Pair<String?, File?>>()
                val swing = mutableListOf<Pair<String?, File?>>()
                val result = chooseDirectory(os, "t", dir.absolutePath, recording(null, native), recording(dir, swing))
                assertEquals(dir.absolutePath, result, os)
                assertEquals(emptyList(), native, os)
                assertEquals(listOf<Pair<String?, File?>>(null to dir), swing, os)
            }
        } finally {
            dir.deleteRecursively()
        }
    }
}
