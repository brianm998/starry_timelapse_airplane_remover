package com.star.desktop.domain

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WorkingLocationTest {
    @Test fun theRunTakesFourTimesTheInput() {
        assertEquals(4_000L, WorkingLocation.runBytes(1_000))
    }

    @Test fun aSequenceIsSizedByItsImagesOnly() {
        val dir = kotlin.io.path.createTempDirectory("seq").toFile()
        try {
            File(dir, "a.tif").writeBytes(ByteArray(100))
            File(dir, "b.JPG").writeBytes(ByteArray(50))
            File(dir, "notes.txt").writeBytes(ByteArray(999))
            File(dir, "sub").mkdir()
            assertEquals(150L, WorkingLocation.sequenceInputBytes(dir))
        } finally { dir.deleteRecursively() }
    }

    /** The folder the output is going to usually is not there yet; the volume is the nearest folder that is. */
    @Test fun freeSpaceIsReadFromTheNearestFolderThatExists() {
        val dir = kotlin.io.path.createTempDirectory("loc").toFile()
        try {
            val free = WorkingLocation.freeBytes(File(dir, "not/yet/here").path)
            assertNotNull(free)
            assertTrue(free > 0)
        } finally { dir.deleteRecursively() }
    }

    @Test fun beingBesideTheSourceIsTheSourcesFolder() {
        assertEquals(File("/Volumes/x/shoots").path, WorkingLocation.defaultFolder("/Volumes/x/shoots/clip.mov"))
    }
}
