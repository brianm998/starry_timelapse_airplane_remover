package com.star.desktop.ui.initial

import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Drag-and-drop routing on the start screen, mirroring macOS `InitialView.handleDrop`. */
class ResolveDropTest {

    @Test
    fun emptyDropIsNull() {
        assertNull(resolveDrop(emptyList()))
    }

    @Test
    fun singleFolderOpensAsSequence() {
        val dir = Files.createTempDirectory("seq").toFile()
        try {
            assertEquals(OpenAction(OpenKind.SEQUENCE, dir.absolutePath), resolveDrop(listOf(dir)))
        } finally {
            dir.delete()
        }
    }

    /** Runs [block] with [names] created as real files in a fresh temp folder, which is removed afterwards. */
    private fun withFiles(vararg names: String, block: (File, List<File>) -> Unit) {
        val dir = Files.createTempDirectory("drop").toFile()
        try {
            block(dir, names.map { File(dir, it).apply { createNewFile() } })
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun singleConfigJsonResumes() = withFiles("config.json") { _, files ->
        assertEquals(OpenAction(OpenKind.CONFIG, files[0].absolutePath), resolveDrop(files))
    }

    @Test
    fun aMissingFileIsReportedNotImported() {
        for (name in listOf("clip.mov", "config.json", "frame_001.jpg", "notes.txt")) {
            val f = File("/tmp/star-no-such-dir/$name")
            assertEquals(MissingFile(f.absolutePath), resolveDrop(listOf(f)), "$name does not exist")
        }
    }

    @Test
    fun singleImageOpensContainingFolderAsSequence() {
        val names = listOf("frame_001.jpg", "frame_001.JPEG", "frame_001.tif", "frame_001.tiff", "frame_001.png")
        withFiles(*names.toTypedArray()) { dir, files ->
            for (f in files) {
                assertEquals(
                    OpenAction(OpenKind.SEQUENCE, dir.absolutePath),
                    resolveDrop(listOf(f)),
                    "image ${f.name} should open its parent folder as a sequence",
                )
            }
        }
    }

    @Test
    fun singleVideoImportsAsVideo() {
        withFiles("clip.mov", "clip.MP4", "clip.m4v") { _, files ->
            for (f in files) {
                assertEquals(OpenAction(OpenKind.VIDEO, f.absolutePath), resolveDrop(listOf(f)), "video ${f.name} should import as a video")
            }
        }
    }

    @Test
    fun multipleFilesOpenTheirContainingFolderAsSequence() {
        val files = listOf(
            File("/tmp/burst/img_01.jpg"),
            File("/tmp/burst/img_02.jpg"),
            File("/tmp/burst/img_03.jpg"),
        )
        assertEquals(
            OpenAction(OpenKind.SEQUENCE, File("/tmp/burst").absolutePath),
            resolveDrop(files),
        )
    }
}
