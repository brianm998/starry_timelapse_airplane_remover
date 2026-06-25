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

    @Test
    fun singleConfigJsonResumes() {
        val f = File("/tmp/some-session/config.json")
        assertEquals(OpenAction(OpenKind.CONFIG, f.absolutePath), resolveDrop(listOf(f)))
    }

    @Test
    fun singleImageOpensContainingFolderAsSequence() {
        for (name in listOf("frame_001.jpg", "frame_001.JPEG", "frame_001.tif", "frame_001.tiff", "frame_001.png")) {
            val f = File("/tmp/my-seq/$name")
            assertEquals(
                OpenAction(OpenKind.SEQUENCE, File("/tmp/my-seq").absolutePath),
                resolveDrop(listOf(f)),
                "image $name should open its parent folder as a sequence",
            )
        }
    }

    @Test
    fun singleVideoImportsAsVideo() {
        for (name in listOf("clip.mov", "clip.MP4", "clip.m4v")) {
            val f = File("/tmp/videos/$name")
            assertEquals(
                OpenAction(OpenKind.VIDEO, f.absolutePath),
                resolveDrop(listOf(f)),
                "video $name should import as a video",
            )
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
