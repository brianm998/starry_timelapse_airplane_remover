package com.star.desktop.util

import com.star.desktop.engine.EngineStatus

/** What this build of the client is: the version `generateBuildInfo` (build.gradle.kts) stamped into the resources. */
object BuildInfo {
    /** The client's own version, `Config.latestVersion` at build time; empty when the resource is missing. */
    val version: String by lazy {
        runCatching {
            BuildInfo::class.java.getResourceAsStream("/star-version.txt")?.use { it.readBytes().toString(Charsets.UTF_8).trim() }
        }.getOrNull().orEmpty()
    }
}

/** The version the start screen's heading shows: the engine's once it has connected, until then this build's own. */
fun headingVersion(engineStatus: EngineStatus, buildVersion: String = BuildInfo.version): String =
    (engineStatus as? EngineStatus.Connected)?.daemonVersion ?: buildVersion
