package com.star.desktop.ui.dialogs

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.i18n.localized
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.util.DesktopOs
import com.star.desktop.util.GitHubRelease
import com.star.desktop.util.OpenUrl
import com.star.desktop.util.ReleaseCheck

/**
 * "There is a new release of Star available" (macOS `NewReleaseSheetView`): the release's notes, links to it and to the installer for
 * this system, and the choice of going on with the old one or quitting to upgrade it. It is told once, at launch; it can be put off.
 */
@Composable
fun NewReleaseDialog(release: GitHubRelease, runningVersion: String, onLater: () -> Unit, onQuit: () -> Unit,
                     os: DesktopOs = DesktopOs.of(System.getProperty("os.name").orEmpty())) {
    val version = release.version?.toString() ?: release.tagName
    val installer = ReleaseCheck.installerFor(release, os)
    PromptCard(onScrimClick = null, onDefaultAction = onLater, onEscape = onLater) {
        Text(localized("ui.there_is_a_new_release_of_star_available"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
        Text(localized("ui.new_release_available", runningVersion, version), color = StarColors.textSecondary, fontSize = 14.sp)

        release.body?.takeIf { it.isNotBlank() }?.let { body ->
            Text(localized("ui.release_notes"), color = StarColors.textPrimary, fontWeight = FontWeight.Medium, fontSize = 14.sp)
            Box(Modifier.fillMaxWidth().heightIn(max = 220.dp).border(1.dp, StarColors.textSecondary.copy(alpha = 0.4f))) {
                Text(body, color = StarColors.textSecondary, fontSize = 13.sp,
                     modifier = Modifier.verticalScroll(rememberScrollState()).padding(10.dp))
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(20.dp), verticalAlignment = Alignment.CenterVertically) {
            if (release.htmlUrl.isNotBlank()) Link(localized("ui.see_release_on_github"), release.htmlUrl)
            installer?.let { Link(localized("ui.download_star", version), it.downloadUrl) }
        }

        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = onLater) { Text(localized("ui.upgrade_later")) }
            Box(Modifier.padding(start = 10.dp))
            Button(onClick = onQuit, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) {
                Text(localized("ui.quit_star", runningVersion))
            }
        }
    }
}

@Composable
private fun Link(text: String, url: String) {
    Text(text, color = StarColors.accent, fontSize = 14.sp, textDecoration = TextDecoration.Underline,
         modifier = Modifier.clickable { OpenUrl.browse(url) })
}
