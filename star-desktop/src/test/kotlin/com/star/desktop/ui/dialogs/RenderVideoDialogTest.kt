package com.star.desktop.ui.dialogs

import com.star.desktop.i18n.localized
import com.star.proto.ProgressEvent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * What the Render Video dialog says when the video is written. It asks the daemon for no path, so
 * the daemon names the file and tells the dialog where it went, and that is all the user has to
 * find the video by.
 */
class RenderVideoDialogTest {

    @Test
    fun theStatusNamesTheVideoWhenTheDaemonSaidWhereItWent() {
        val path = "/Users/someone/Movies/night sky-star-v-0_11_5.mov"

        val status = renderedStatus(path)

        assertTrue(status.contains(path), "the status does not show the path: $status")
    }

    /** The sentence comes from the catalogue the Mac app's dialog uses, not from a copy made here. */
    @Test
    fun theStatusIsTheCataloguesSentenceSoItReadsInTheUsersLanguage() {
        assertEquals(localized("ui.successfully_rendered", "/x.mov"), renderedStatus("/x.mov"))
    }

    /** An engine older than the event never says where, and the dialog still has to finish. */
    @Test
    fun theStatusIsJustDoneWhenTheDaemonDidNotSayWhere() {
        assertEquals("Done", renderedStatus(null))
        assertEquals("Done", renderedStatus(""))
    }

    /** A Mac has a Finder, and the catalogue says so in every language; the others have none. */
    @Test
    fun theRevealButtonSaysFinderOnAMacAndFolderElsewhere() {
        assertEquals(localized("ui.reveal_in_finder"), revealLabel("Mac OS X"))
        assertEquals(localized("ui.show_in_folder"), revealLabel("Windows 11"))
        assertEquals(localized("ui.show_in_folder"), revealLabel("Linux"))
    }

    /** The two labels have to be told apart, or the test above would pass for any key that is missing. */
    @Test
    fun bothRevealLabelsExistAndDiffer() {
        val finder = localized("ui.reveal_in_finder")
        val folder = localized("ui.show_in_folder")

        assertTrue(finder != "ui.reveal_in_finder", "the catalogue has no ui.reveal_in_finder")
        assertTrue(folder != "ui.show_in_folder", "the catalogue has no ui.show_in_folder")
        assertTrue(finder != folder, "$finder / $folder")
    }

    /**
     * The bytes stard sends, spelt out: its own test (ExportVideoSettingsTests) asserts it produces
     * exactly these, so the two clients cannot drift apart on the field numbers without a test of
     * one of them failing. `3A 08` is field 7 (`video_exported`) holding 8 bytes; `0A 06` is
     * field 1 (the path) of 6.
     */
    @Test
    fun theDialogReadsTheEventStardSends() {
        val sent = byteArrayOf(0x3A, 0x08, 0x0A, 0x06, 0x2F, 0x78, 0x2E, 0x6D, 0x6F, 0x76)

        val event = ProgressEvent.parseFrom(sent)

        assertEquals(ProgressEvent.KindCase.VIDEO_EXPORTED, event.kindCase)
        assertEquals("/x.mov", event.videoExported.outputVideoPath)
    }
}
