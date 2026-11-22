package com.star.desktop.domain

import com.star.desktop.data.LocalPreferences
import com.star.proto.Warning
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** stard's `gpuMergeTurnedOff` warning turns the machine-wide GPU merge preference off; no other kind touches it. `user.home` is a temp directory. */
class GpuMergeTurnedOffTest {
    private lateinit var home: File
    private var savedHome: String? = null

    @BeforeTest fun redirectHome() {
        savedHome = System.getProperty("user.home")
        home = Files.createTempDirectory("star-gpu-merge-test").toFile()
        System.setProperty("user.home", home.absolutePath)
    }

    @AfterTest fun restoreHome() {
        savedHome?.let { System.setProperty("user.home", it) } ?: System.clearProperty("user.home")
        home.deleteRecursively()
    }

    private fun warning(kind: String) = Warning.newBuilder().setKind(kind).setSeverity("warning").build()

    @Test fun theWarningTurnsGpuMergeOffAndTheUserCanTurnItBackOn() {
        val prefs = LocalPreferences()
        prefs.setGpu(GpuToggle.MERGE, true)
        assertTrue(GpuMergeTurnedOff.apply(warning("gpuMergeTurnedOff"), prefs))
        assertEquals(false, prefs.gpu(GpuToggle.MERGE))
        assertEquals(false, LocalPreferences().gpu(GpuToggle.MERGE), "persisted, so the next session starts with it off")
        prefs.setGpu(GpuToggle.MERGE, true)
        assertEquals(true, LocalPreferences().gpu(GpuToggle.MERGE))
    }

    @Test fun otherKindsLeaveThePreferenceAlone() {
        val prefs = LocalPreferences()
        assertFalse(GpuMergeTurnedOff.apply(warning("previousRunDied"), prefs))
        assertNull(prefs.gpu(GpuToggle.MERGE))
        prefs.setGpu(GpuToggle.MERGE, true)
        assertFalse(GpuMergeTurnedOff.apply(warning("lowDiskSpace"), prefs))
        assertEquals(true, prefs.gpu(GpuToggle.MERGE))
    }
}
