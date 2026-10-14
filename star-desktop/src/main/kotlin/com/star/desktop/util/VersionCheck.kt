package com.star.desktop.util

import com.star.desktop.i18n.localized

/**
 * §4.4 version-mismatch warning: a non-null message when a resumed session's recorded
 * `config.starVersion` differs from the running engine version, else null. Pure so it's unit-testable.
 * Empty/unknown versions never warn (a freshly-opened sequence records the current engine version).
 */
fun versionMismatchWarning(sessionVersion: String?, engineVersion: String?): String? =
    if (!sessionVersion.isNullOrEmpty() && !engineVersion.isNullOrEmpty() && sessionVersion != engineVersion) {
        localized("ui.sequence_processed_with_other_version", sessionVersion, engineVersion)
    } else {
        null
    }
