package com.star.desktop.ui.dialogs

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import com.star.desktop.ui.theme.StarTheme
import com.star.desktop.util.DesktopOs
import com.star.desktop.util.GitHubRelease
import com.star.desktop.util.ReleaseAsset
import org.jetbrains.skia.EncodedImageFormat
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The new-release dialog composes, says what the macOS sheet says, and its strings are in every language. With `-Dstar.render.dump=<dir>` the picture is written there. */
@OptIn(ExperimentalComposeUiApi::class)
class NewReleaseDialogTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private val release = GitHubRelease(
        tagName = "release/0.12.0", htmlUrl = "https://github.com/x/y/releases/tag/release/0.12.0",
        body = (1..40).joinToString("\n") { "- change number $it, a thing that was fixed or made better" },
        assets = listOf(ReleaseAsset("Star-0.12.0.dmg", "https://example.com/Star-0.12.0.dmg")),
    )

    @Test fun theDialogDrawsOverAScrim() {
        val scene = ImageComposeScene(width = 900, height = 700, density = Density(1f)) {
            StarTheme { NewReleaseDialog(release, "0.11.1", onLater = {}, onQuit = {}, os = DesktopOs.MAC) }
        }
        try {
            scene.render()
            val image = scene.render(100_000_000)
            val bytes = image.encodeToData(EncodedImageFormat.PNG)!!.bytes
            System.getProperty("star.render.dump")?.takeIf { it.isNotBlank() }?.let { File(it, "new_release.png").apply { parentFile.mkdirs() }.writeBytes(bytes) }
            val bitmap = org.jetbrains.skia.Bitmap.makeFromImage(image)
            val colours = HashSet<Int>()
            for (y in 0 until bitmap.height step 4) for (x in 0 until bitmap.width step 4) colours += bitmap.getColor(x, y)
            assertTrue(colours.size > 4, "more than a flat fill: the card, its text and its buttons")
        } finally {
            scene.close()
        }
    }

    @Test fun theSheetsStringsAreFormattedWithTheVersions() {
        assertEquals("You are running Star v0.11.1, and Star v0.12.0 is now available", localized("ui.new_release_available", "0.11.1", "0.12.0"))
        assertEquals("Quit Star v0.11.1", localized("ui.quit_star", "0.11.1"))
        assertEquals("Download Star v0.12.0", localized("ui.download_star", "0.12.0"))
    }

    @Test fun theStringsAreInEveryLanguage() {
        val keys = listOf("ui.there_is_a_new_release_of_star_available", "ui.new_release_available", "ui.release_notes", "ui.see_release_on_github",
                          "ui.download_star", "ui.upgrade_later", "ui.quit_star")
        for (code in Strings.languages.map { it.code }) {
            Strings.setOverride(code)
            try {
                for (key in keys) assertFalse(localized(key, "1", "2") == key, "$code: $key")
            } finally {
                Strings.setOverride("en")
            }
        }
    }
}
