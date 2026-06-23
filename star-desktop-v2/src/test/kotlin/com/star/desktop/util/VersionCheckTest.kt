package com.star.desktop.util

import kotlin.test.Test
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** §8.6: the version-mismatch warning fires only when both versions are known and differ. */
class VersionCheckTest {

    @Test
    fun differingVersionsWarn() {
        val msg = versionMismatchWarning(sessionVersion = "0.9.0", engineVersion = "0.11.1")
        assertTrue(msg != null && msg.contains("0.9.0") && msg.contains("0.11.1"))
    }

    @Test
    fun matchingVersionDoesNotWarn() {
        assertNull(versionMismatchWarning("0.11.1", "0.11.1"))
    }

    @Test
    fun unknownVersionsDoNotWarn() {
        assertNull(versionMismatchWarning(null, "0.11.1"))
        assertNull(versionMismatchWarning("0.11.1", null))
        assertNull(versionMismatchWarning("", "0.11.1"))
        assertNull(versionMismatchWarning("0.11.1", ""))
    }
}
