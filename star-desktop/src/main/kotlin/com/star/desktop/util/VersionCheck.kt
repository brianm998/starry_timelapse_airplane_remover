package com.star.desktop.util

/**
 * §4.4 version-mismatch warning: a non-null message when a resumed session's recorded
 * `config.starVersion` differs from the running engine version, else null. Pure so it's unit-testable.
 * Empty/unknown versions never warn (a freshly-opened sequence records the current engine version).
 */
fun versionMismatchWarning(sessionVersion: String?, engineVersion: String?): String? =
    if (!sessionVersion.isNullOrEmpty() && !engineVersion.isNullOrEmpty() && sessionVersion != engineVersion) {
        "This sequence was last processed with Star $sessionVersion; the engine is $engineVersion."
    } else {
        null
    }
