package com.star.desktop.util

import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import com.google.gson.reflect.TypeToken
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration

/** A release's version as three numbers, compared the way the Mac app compares them: a patch that is not higher is not newer (macOS `ReleaseVersion`). */
data class ReleaseVersion(val major: Int, val minor: Int, val patch: Int) {
    override fun toString(): String = "$major.$minor.$patch"

    operator fun compareTo(other: ReleaseVersion): Int = when {
        major != other.major -> major.compareTo(other.major)
        minor != other.minor -> minor.compareTo(other.minor)
        else -> patch.compareTo(other.patch)
    }

    companion object {
        /** "0.12.4" or a tag ("release/0.12.4": the part after the last slash); null for anything that is not three numbers. */
        fun parse(text: String?): ReleaseVersion? {
            val parts = text?.substringAfterLast('/')?.trim()?.split('.') ?: return null
            if (parts.size != 3) return null
            val numbers = parts.map { it.toIntOrNull() ?: return null }
            return ReleaseVersion(numbers[0], numbers[1], numbers[2])
        }
    }
}

/** One file attached to a release. */
data class ReleaseAsset(val name: String, @SerializedName("browser_download_url") val downloadUrl: String)

/** A release as GitHub's API describes it (macOS `GitHubRelease`): the fields the new-release dialog uses. */
data class GitHubRelease(
    @SerializedName("tag_name") val tagName: String = "",
    val name: String? = null,
    val body: String? = null,
    val draft: Boolean = false,
    val prerelease: Boolean = false,
    @SerializedName("html_url") val htmlUrl: String = "",
    val assets: List<ReleaseAsset> = emptyList(),
) {
    val version: ReleaseVersion? get() = ReleaseVersion.parse(tagName)
}

/** Which installer a release has for which system. */
enum class DesktopOs { MAC, WINDOWS, LINUX;
    companion object {
        fun of(osName: String): DesktopOs {
            val n = osName.lowercase()
            return when {
                "mac" in n || "darwin" in n -> MAC
                "win" in n -> WINDOWS
                else -> LINUX
            }
        }
    }
}

/**
 * Is there a newer release (macOS `StarCore.newRelease`): GitHub's list of releases for the project, compared with the version running, and the
 * installer for this system out of what the newest one has attached. Offline, or if GitHub does not answer, there is simply nothing to say.
 */
object ReleaseCheck {
    const val RELEASES_URL = "https://api.github.com/repos/brianm998/starry_timelapse_airplane_remover/releases"

    private val gson = Gson()

    fun parse(json: String): List<GitHubRelease> =
        gson.fromJson<List<GitHubRelease>>(json, object : TypeToken<List<GitHubRelease>>() {}.type).orEmpty()

    /**
     * The newest release that is newer than [running], or null. The Mac app takes the first of GitHub's list, which it assumes is the latest; the
     * highest version is taken here, so a list that happens to be in another order does not hide one. Drafts are not releases yet.
     */
    fun newer(running: String, releases: List<GitHubRelease>): GitHubRelease? {
        val current = ReleaseVersion.parse(running) ?: return null
        return releases.filter { !it.draft }
            .mapNotNull { r -> r.version?.let { r to it } }
            .filter { (_, v) -> v > current }
            .maxByOrNull { (_, v) -> v.major * 1_000_000L + v.minor * 1_000L + v.patch }
            ?.first
    }

    /**
     * The installer in [release] for [os]: what the desktop build's installers are called (the Compose packager's `Star-<version>.dmg` and
     * `.exe`, and its `star_<version>-1_amd64.deb`). The Mac app's own `star_app_` and the command line's `star_cli_` are not this client's.
     */
    fun installerFor(release: GitHubRelease, os: DesktopOs): ReleaseAsset? {
        val extension = when (os) { DesktopOs.MAC -> ".dmg"; DesktopOs.WINDOWS -> ".exe"; DesktopOs.LINUX -> ".deb" }
        return release.assets.firstOrNull { a ->
            val n = a.name.lowercase()
            n.endsWith(extension) && (n.startsWith("star-") || n.startsWith("star_")) && !n.startsWith("star_app_") && !n.startsWith("star_cli_")
        }
    }

    /** Ask GitHub and compare. Null for nothing newer, and for any trouble reaching it: this runs at launch and must never be the reason something fails. */
    suspend fun check(running: String, fetch: suspend () -> String = ::fetchReleasesJson): GitHubRelease? =
        try {
            newer(running, parse(fetch()))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w("Release") { "unable to check for a new release: ${e.message}" }
            null
        }

    private suspend fun fetchReleasesJson(): String = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        val client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).followRedirects(HttpClient.Redirect.NORMAL).build()
        val request = HttpRequest.newBuilder(URI.create(RELEASES_URL)).timeout(Duration.ofSeconds(20)).header("Accept", "application/vnd.github+json").GET().build()
        val response = client.send(request, HttpResponse.BodyHandlers.ofString())
        check(response.statusCode() == 200) { "GitHub answered ${response.statusCode()}" }
        response.body()
    }
}
