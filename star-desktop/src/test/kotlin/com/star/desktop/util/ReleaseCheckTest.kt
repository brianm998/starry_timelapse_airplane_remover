package com.star.desktop.util

import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** H5: the check for a new release, and what it makes of GitHub's answer. */
class ReleaseCheckTest {
    private fun release(tag: String, draft: Boolean = false, assets: List<String> = emptyList()) =
        GitHubRelease(tagName = tag, draft = draft, htmlUrl = "https://github.com/x/y/releases/tag/$tag",
                      assets = assets.map { ReleaseAsset(it, "https://example.com/$it") })

    @Test fun aVersionIsThreeNumbers() {
        assertEquals(ReleaseVersion(0, 12, 4), ReleaseVersion.parse("0.12.4"))
        assertNull(ReleaseVersion.parse("0.12"))
        assertNull(ReleaseVersion.parse("0.12.4.1"))
        assertNull(ReleaseVersion.parse("v0.12.4"))
        assertNull(ReleaseVersion.parse("0.12.x"))
        assertNull(ReleaseVersion.parse(""))
        assertNull(ReleaseVersion.parse(null))
    }

    @Test fun aTagIsItsPartAfterTheLastSlash() {
        assertEquals(ReleaseVersion(1, 2, 3), ReleaseVersion.parse("release/1.2.3"))
        assertEquals(ReleaseVersion(1, 2, 3), ReleaseVersion.parse("a/b/1.2.3"))
    }

    @Test fun versionsCompareNumberByNumberNotAsText() {
        assertTrue(ReleaseVersion(0, 10, 0) > ReleaseVersion(0, 9, 9))
        assertTrue(ReleaseVersion(1, 0, 0) > ReleaseVersion(0, 99, 99))
        assertTrue(ReleaseVersion(0, 0, 10) > ReleaseVersion(0, 0, 9))
        assertFalse(ReleaseVersion(0, 11, 1) > ReleaseVersion(0, 11, 1), "the same version is not newer")
        assertFalse(ReleaseVersion(0, 11, 0) > ReleaseVersion(0, 11, 1))
    }

    @Test fun theNewestReleaseNewerThanTheOneRunningIsTheOneToTellAbout() {
        val releases = listOf(release("release/0.11.2"), release("release/0.13.0"), release("release/0.12.5"))
        assertEquals("release/0.13.0", ReleaseCheck.newer("0.11.1", releases)?.tagName, "whatever order GitHub lists them in")
        assertEquals("release/0.13.0", ReleaseCheck.newer("0.12.9", releases)?.tagName)
    }

    @Test fun nothingNewerIsNothing() {
        val releases = listOf(release("release/0.11.1"), release("release/0.10.0"))
        assertNull(ReleaseCheck.newer("0.11.1", releases), "the one running is the latest")
        assertNull(ReleaseCheck.newer("0.12.0", releases), "a build ahead of the releases")
        assertNull(ReleaseCheck.newer("0.11.1", emptyList()))
    }

    @Test fun aDraftIsNotAReleaseYet() {
        assertNull(ReleaseCheck.newer("0.11.1", listOf(release("release/0.12.0", draft = true))))
        assertEquals("release/0.11.5", ReleaseCheck.newer("0.11.1", listOf(release("release/0.12.0", draft = true), release("release/0.11.5")))?.tagName)
    }

    @Test fun aTagThatIsNotAVersionIsSkippedAndAnUnknownRunningVersionAsksNothing() {
        assertNull(ReleaseCheck.newer("0.11.1", listOf(release("nightly"))))
        assertNull(ReleaseCheck.newer("unknown", listOf(release("release/0.12.0"))))
    }

    private val assets = listOf(
        "star_app_0.12.0.dmg", "star_cli_0.12.0.tar.gz", "Star-0.12.0.dmg", "Star-0.12.0.exe", "star_0.12.0-1_amd64.deb", "Star-0.12.0.msi",
    )

    @Test fun eachSystemGetsItsOwnInstaller() {
        val r = release("release/0.12.0", assets = assets)
        assertEquals("Star-0.12.0.dmg", ReleaseCheck.installerFor(r, DesktopOs.MAC)?.name)
        assertEquals("Star-0.12.0.exe", ReleaseCheck.installerFor(r, DesktopOs.WINDOWS)?.name)
        assertEquals("star_0.12.0-1_amd64.deb", ReleaseCheck.installerFor(r, DesktopOs.LINUX)?.name)
    }

    @Test fun theMacAppsOwnDiskImageIsNotThisClientsInstaller() {
        val r = release("release/0.12.0", assets = listOf("star_app_0.12.0.dmg", "star_cli_0.12.0.tar.gz"))
        assertNull(ReleaseCheck.installerFor(r, DesktopOs.MAC))
        assertNull(ReleaseCheck.installerFor(r, DesktopOs.LINUX))
    }

    @Test fun aReleaseWithoutAnInstallerForThisSystemHasNone() {
        val r = release("release/0.12.0", assets = listOf("Star-0.12.0.dmg"))
        assertNull(ReleaseCheck.installerFor(r, DesktopOs.WINDOWS))
        assertNull(ReleaseCheck.installerFor(release("release/0.12.0"), DesktopOs.MAC))
    }

    @Test fun fileNamesAreMatchedWithoutRegardToCase() {
        assertEquals("STAR-0.12.0.DMG", ReleaseCheck.installerFor(release("release/0.12.0", assets = listOf("STAR-0.12.0.DMG")), DesktopOs.MAC)?.name)
    }

    @Test fun theOperatingSystemNameChoosesTheSystem() {
        assertEquals(DesktopOs.MAC, DesktopOs.of("Mac OS X"))
        assertEquals(DesktopOs.WINDOWS, DesktopOs.of("Windows 11"))
        assertEquals(DesktopOs.LINUX, DesktopOs.of("Linux"))
    }

    @Test fun githubsJsonIsRead() {
        val json = """
            [
              {"tag_name": "release/0.12.0", "name": "Star 0.12.0", "body": "- a fix\n- another", "draft": false, "prerelease": false,
               "html_url": "https://github.com/x/y/releases/tag/release/0.12.0", "id": 5, "author": {"login": "someone"},
               "assets": [{"name": "Star-0.12.0.dmg", "browser_download_url": "https://github.com/x/y/releases/download/release/0.12.0/Star-0.12.0.dmg", "size": 12}]},
              {"tag_name": "release/0.11.0"}
            ]
        """.trimIndent()
        val releases = ReleaseCheck.parse(json)
        assertEquals(2, releases.size)
        val first = releases[0]
        assertEquals(ReleaseVersion(0, 12, 0), first.version)
        assertEquals("- a fix\n- another", first.body)
        assertEquals("https://github.com/x/y/releases/tag/release/0.12.0", first.htmlUrl)
        assertEquals("https://github.com/x/y/releases/download/release/0.12.0/Star-0.12.0.dmg", ReleaseCheck.installerFor(first, DesktopOs.MAC)?.downloadUrl)
        assertNull(releases[1].body, "a release with no notes")
        assertTrue(releases[1].assets.isEmpty())
    }

    @Test fun checkingFindsTheNewerRelease() = runBlocking {
        val found = ReleaseCheck.check("0.11.1") { """[{"tag_name": "release/0.12.0"}, {"tag_name": "release/0.11.1"}]""" }
        assertNotNull(found)
        assertEquals("release/0.12.0", found.tagName)
    }

    @Test fun checkingSaysNothingWhenThereIsNothingNewOrNothingCouldBeReached() = runBlocking {
        assertNull(ReleaseCheck.check("0.11.1") { """[{"tag_name": "release/0.11.1"}]""" })
        assertNull(ReleaseCheck.check("0.11.1") { throw java.io.IOException("offline") }, "no network")
        assertNull(ReleaseCheck.check("0.11.1") { "<html>rate limited</html>" }, "not JSON")
        assertNull(ReleaseCheck.check("0.11.1") { """{"message": "API rate limit exceeded"}""" }, "an error object, not a list")
        assertNull(ReleaseCheck.check("0.11.1") { "" }, "an empty answer")
    }
}
