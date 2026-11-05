package com.star.desktop.ui.initial

import java.awt.datatransfer.DataFlavor
import java.awt.datatransfer.Transferable
import java.awt.datatransfer.UnsupportedFlavorException
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Which drags the start screen's drop zone accepts, and which files it takes from them. */
class DroppedFilesTest {

    private val uriList = DataFlavor("text/uri-list;class=java.lang.String")

    /** A transferable offering exactly [data], keyed by flavor. */
    private fun transferable(vararg data: Pair<DataFlavor, Any>): Transferable = object : Transferable {
        override fun getTransferDataFlavors() = data.map { it.first }.toTypedArray()
        override fun isDataFlavorSupported(flavor: DataFlavor) = data.any { it.first.equals(flavor) }
        override fun getTransferData(flavor: DataFlavor): Any =
            data.firstOrNull { it.first.equals(flavor) }?.second ?: throw UnsupportedFlavorException(flavor)
    }

    @Test
    fun aTextDragIsNotAFileDrag() {
        val text = transferable(DataFlavor.stringFlavor to "https://example.com/some link")
        assertFalse(isFileDrag(text))
        assertEquals(emptyList(), droppedFiles(text))
    }

    @Test
    fun aJavaFileListIsAFileDrag() {
        val files = listOf(File("/tmp/a.jpg"), File("/tmp/b.jpg"))
        val t = transferable(DataFlavor.javaFileListFlavor to files)
        assertTrue(isFileDrag(t))
        assertEquals(files, droppedFiles(t))
    }

    @Test
    fun aUriListGivesTheFiles() {
        val list = "# dropped from a file manager\r\n" +
            "file:///tmp/burst/img_01.jpg\r\n" +
            "\r\n" +
            "file:///tmp/burst/my%20frame.jpg\r\n" +
            "https://example.com/not-a-file.jpg\r\n" +
            "file:///tmp/burst/img_03.jpg\r\n"
        val t = transferable(uriList to list)
        assertTrue(isFileDrag(t))
        assertEquals(
            listOf(File("/tmp/burst/img_01.jpg"), File("/tmp/burst/my frame.jpg"), File("/tmp/burst/img_03.jpg")),
            droppedFiles(t),
        )
    }
}
