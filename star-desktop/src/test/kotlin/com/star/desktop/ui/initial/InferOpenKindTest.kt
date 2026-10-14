package com.star.desktop.ui.initial

import kotlin.test.Test
import kotlin.test.assertEquals

/** How a recent entry, or a path from the command line, is opened. */
class InferOpenKindTest {
    @Test fun aSessionsConfigResumesIt() {
        assertEquals(OpenKind.CONFIG, inferOpenKind("/Volumes/x/star_temp_milky_way/config.json"))
    }

    /** Any `.json` is a config: the macOS app opens whatever file it recorded as one. */
    @Test fun anyJsonFileIsAConfig() {
        assertEquals(OpenKind.CONFIG, inferOpenKind("/Volumes/x/my-session.JSON"))
    }

    /** Entries recorded before configs were what got recorded are folders and videos. */
    @Test fun olderEntriesAreStillFoldersAndVideos() {
        assertEquals(OpenKind.SEQUENCE, inferOpenKind("/Volumes/x/milky_way"))
        assertEquals(OpenKind.VIDEO, inferOpenKind("/Volumes/x/clip.MOV"))
    }
}

/** The config chooser offers `.json` files and the folders to reach them, whatever the case of the extension. */
class ChooserFilterTest {
    @Test fun anExtensionIsMatchedWithoutRegardToCase() {
        assertEquals(true, hasExtension("config.json", setOf("json")))
        assertEquals(true, hasExtension("CONFIG.JSON", setOf("json")))
        assertEquals(false, hasExtension("config.json.bak", setOf("json")))
        assertEquals(false, hasExtension("notes.txt", setOf("json")))
        assertEquals(false, hasExtension("json", setOf("json")), "a name with no dot has no extension")
        assertEquals(true, hasExtension("a.mov", setOf("json", "mov")))
    }
}
