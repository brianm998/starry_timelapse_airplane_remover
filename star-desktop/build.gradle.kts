import com.google.protobuf.gradle.id
import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("jvm") version "2.1.0"
    id("org.jetbrains.compose") version "1.7.3"
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.0"
    id("com.google.protobuf") version "0.9.4"
}

group = "com.star.desktop"
version = "2.0.0"

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
}

sourceSets {
    main {
        proto.srcDir("proto")
    }
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)

    // Proto messages only — NO gRPC plugin (transport is hand-rolled stdio framing).
    implementation("com.google.protobuf:protobuf-kotlin-lite:4.28.3")

    // Coroutines: core + Swing dispatcher (Compose Desktop runs on the AWT/Swing EDT).
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.9.0")

    // JSON for client-local prefs (~/.star.userprefs.json) — the ONLY file the client serializes.
    implementation("com.google.code.gson:gson:2.11.0")

    testImplementation(kotlin("test"))
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}

// Generate protobuf-java-lite + protobuf-kotlin-lite extensions. No gRPC.
protobuf {
    protoc {
        artifact = "com.google.protobuf:protoc:4.28.3"
    }
    generateProtoTasks {
        all().forEach { task ->
            task.builtins {
                named("java") { option("lite") }
                id("kotlin") { option("lite") }
            }
        }
    }
}

// Developer ID identity for signing the macOS distribution (null → unsigned). Declared before the
// compose.desktop block so it resolves inside the nested nativeDistributions DSL.
val macSignIdentity: String? = (findProperty("star.sign.identity") as String?) ?: System.getenv("STAR_SIGN_IDENTITY")

compose.desktop {
    application {
        mainClass = "com.star.desktop.MainKt"
        // jpackage is absent from some JDKs used to run Gradle (notably the JetBrains Runtime that ships
        // with Android Studio). Point the packaging step at a full JDK (21+, with jpackage) without
        // changing the JVM used for compilation: -Pstar.jpackage.jdk=/path or STAR_JPACKAGE_JDK env.
        (findProperty("star.jpackage.jdk") as String? ?: System.getenv("STAR_JPACKAGE_JDK"))?.let { javaHome = it }
        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "Star"
            packageVersion = "2.0.0"
            description = "Star — Nighttime Timelapse Airplane Remover"
            vendor = "Star"
            // Bundle the native daemon (stard) + ffmpeg/ffprobe so the app is self-contained. The
            // `stageAppResources` task copies the host-OS binaries into app-resources/<os-arch>/ before
            // packaging; Compose merges that dir into the app and exposes it at runtime via the
            // `compose.application.resources.dir` system property. ffmpeg/ffprobe sit next to stard there,
            // so StarCore.ToolPaths (sibling-of-executable) resolves them with no daemon code change.
            appResourcesRootDir.set(layout.projectDirectory.dir("app-resources"))
            includeAllModules = true // the daemon-driving GUI loads classes reflectively; ship the full JDK module set
            macOS {
                bundleID = "com.star.desktop"
                // Optional Developer ID signing (off by default → an unsigned app image). Enable with
                // -Pstar.sign.identity="Developer ID Application: Name (TEAMID)" or STAR_SIGN_IDENTITY.
                // Signs the .app and its embedded native binaries (stard/ffmpeg/ffprobe) with the hardened
                // runtime; entitlements allow the JVM + unsigned-3rd-party tools to run (notarization is separate).
                if (!macSignIdentity.isNullOrBlank()) {
                    signing {
                        sign.set(true)
                        identity.set(macSignIdentity)
                    }
                    entitlementsFile.set(project.file("packaging/macos-entitlements.plist"))
                    runtimeEntitlementsFile.set(project.file("packaging/macos-entitlements.plist"))
                }
            }
        }
    }
}

// Host platform → the app-resources subdir Compose copies for this build (matches Compose's own naming).
val hostResourceDir: String = run {
    val os = System.getProperty("os.name").lowercase()
    val arch = System.getProperty("os.arch").lowercase()
    val a = if (arch.contains("aarch64") || arch.contains("arm")) "arm64" else "x64"
    when {
        os.contains("mac") || os.contains("darwin") -> "macos-$a"
        os.contains("win") -> "windows-$a"
        else -> "linux-$a"
    }
}

// Stage the native daemon + ffmpeg/ffprobe into app-resources/<os-arch>/ for the bundle.
//   stard:   -Pstard=<path>, else daemon/.build/release/stard, else daemon/.build/debug/stard
//   ffmpeg:  -Pffmpegdir=<dir>, else repo-root external_binaries/bin
tasks.register("stageAppResources") {
    group = "star"
    description = "Copy host-OS stard + ffmpeg/ffprobe into app-resources/<os-arch>/ for nativeDistributions bundling."
    // `run`/`runDistributable`/`prepareAppResources` also pull this in, and there the daemon is resolved at
    // runtime from the dev build tree — so a missing stard must NOT fail those. Only a real packaging task
    // (package*/createDistributable*) treats a missing daemon as fatal, to avoid silently shipping a daemon-less app.
    val packagingRequested = gradle.startParameter.taskNames.any {
        val t = it.substringAfterLast(':')
        t.startsWith("package") || t.startsWith("createDistributable") || t.startsWith("createRelease")
    }
    doLast {
        val isWin = hostResourceDir.startsWith("windows")
        val exe = if (isWin) ".exe" else ""
        val outDir = layout.projectDirectory.dir("app-resources/$hostResourceDir").asFile
        outDir.mkdirs()

        fun stage(src: File, name: String) {
            if (!src.exists()) { logger.warn("stageAppResources: $name not found at $src — skipping"); return }
            val dst = File(outDir, name)
            src.copyTo(dst, overwrite = true)
            dst.setExecutable(true, false)
            logger.lifecycle("stageAppResources: ${dst.relativeTo(projectDir)} (${src.length() / 1_000_000}MB)")
        }

        val stardName = "stard$exe"
        val stard = listOfNotNull(
            (findProperty("stard") as String?)?.let { file(it) },
            rootProject.file("../daemon/.build/release/$stardName"),
            rootProject.file("../daemon/.build/debug/$stardName"),
        ).firstOrNull { it.exists() }
        if (stard == null) {
            val msg = "stageAppResources: stard not found — build it (cd daemon && swift build -c release) or pass -Pstard=/path/to/$stardName. The bundle will contain NO daemon."
            if (packagingRequested) throw GradleException(msg)
            logger.warn("$msg (dev run resolves stard from the build tree, so continuing)")
            return@doLast
        }
        stage(stard, stardName)

        val ffDir = (findProperty("ffmpegdir") as String?)?.let { file(it) } ?: rootProject.file("../external_binaries/bin")
        stage(File(ffDir, "ffmpeg$exe"), "ffmpeg$exe")
        stage(File(ffDir, "ffprobe$exe"), "ffprobe$exe")
    }
}

// Compose's prepareAppResources copies app-resources into the image; stage the binaries first.
tasks.matching { it.name == "prepareAppResources" }.configureEach { dependsOn("stageAppResources") }

// Always launch the dev app against a RELEASE daemon. Debug Swift runs the StarCore image pipeline
// ~5-10x slower, and no debugger is ever attached to stard under the Kotlin client, so `run`/`smoke`
// compile the daemon in release first. Incremental: a near no-op when the daemon source is unchanged.
// Lenient: if the Swift toolchain or the daemon's native deps (opencv/StarDecisionTrees — present only
// in a full checkout) are unavailable, warn and continue; DaemonProcess.resolveStardBinary then falls
// back to any existing stard. CI builds release separately (kotlin-client.yml); packaging bundles the
// release binary via stageAppResources (which already prefers .build/release over .build/debug).
tasks.register("buildStardRelease") {
    group = "star"
    description = "Compile the stard daemon in release mode (the fast path) before a dev launch."
    val daemonDir = rootProject.file("../daemon")
    val repoRoot = rootProject.file("..")
    val releaseBin = File(daemonDir, ".build/release/${if (hostResourceDir.startsWith("windows")) "stard.exe" else "stard"}")
    // Up-to-date check: SwiftPM's own scan is slow (~50s) even when nothing changed, so let GRADLE
    // decide whether to invoke it. Inputs = every LOCAL Swift source the daemon compiles (itself + the
    // StarCore/StarCpp/logging path-deps) + the manifest/lockfile (external dep versions). opencv and
    // StarDecisionTrees are immutable prebuilt artifacts, so they're intentionally not tracked.
    inputs.files(
        File(daemonDir, "Package.swift"),
        File(daemonDir, "Package.resolved"),
        fileTree(File(daemonDir, "Sources")),
        fileTree(File(repoRoot, "StarCore/Sources")),
        fileTree(File(repoRoot, "StarCpp/Sources")),
        fileTree(File(repoRoot, "logging/Sources")),
    ).withPropertyName("swiftSources")
    outputs.file(releaseBin).withPropertyName("stardReleaseBinary")
    onlyIf { File(daemonDir, "Package.swift").exists() }
    doLast {
        try {
            val code = ProcessBuilder("swift", "build", "-c", "release")
                .directory(daemonDir).inheritIO().start().waitFor()
            if (code == 0) logger.lifecycle("buildStardRelease: stard release ready ($releaseBin)")
            else logger.warn("buildStardRelease: `swift build -c release` exited $code — using any existing stard")
        } catch (e: Exception) {
            logger.warn("buildStardRelease: could not run `swift` (${e.message}) — using any existing stard")
        }
    }
}

// `run` (Compose dev launch — resolves stard from the build tree) always uses a release daemon.
tasks.matching { it.name == "run" }.configureEach { dependsOn("buildStardRelease") }

// jpackage copies appResources as DATA: it strips the execute bit and does not code-sign them. So after the
// app image is built, restore +x on the bundled binaries and (when signing) codesign each with the hardened
// runtime + entitlements, then re-seal the .app. Without this the shipped app can't spawn the daemon, and a
// signed/notarized build would be rejected for unsigned nested executables. (macOS-only; no-op elsewhere.)
tasks.register("fixBundledBinaries") {
    group = "star"
    description = "chmod +x and codesign the bundled stard/ffmpeg/ffprobe inside the built .app, then re-seal it."
    doLast {
        val id = macSignIdentity
        val ent = layout.projectDirectory.file("packaging/macos-entitlements.plist").asFile
        val apps = layout.buildDirectory.dir("compose/binaries").get().asFile.listFiles().orEmpty()
            .flatMap { File(it, "app").listFiles().orEmpty().toList() }
            .filter { it.name.endsWith(".app") }
        if (apps.isEmpty()) { logger.warn("fixBundledBinaries: no .app under build/compose/binaries — nothing to do"); return@doLast }
        for (app in apps) {
            val resDir = File(app, "Contents/app/resources")
            val bins = listOf("stard", "ffmpeg", "ffprobe").map { File(resDir, it) }.filter { it.exists() }
            if (bins.isEmpty()) continue
            bins.forEach { it.setExecutable(true, false) }
            if (!id.isNullOrBlank()) {
                // Sign nested executables first, then re-seal the bundle (signing inner code invalidates the outer seal).
                bins.forEach { bin ->
                    exec { commandLine("codesign", "--force", "--options", "runtime", "--timestamp", "--entitlements", ent.absolutePath, "--sign", id, bin.absolutePath) }
                }
                exec { commandLine("codesign", "--force", "--options", "runtime", "--timestamp", "--entitlements", ent.absolutePath, "--sign", id, app.absolutePath) }
                logger.lifecycle("fixBundledBinaries: signed ${bins.size} bundled binaries + re-sealed ${app.name}")
            } else {
                logger.lifecycle("fixBundledBinaries: chmod +x ${bins.size} bundled binaries in ${app.name} (unsigned build)")
            }
        }
    }
}
// Run the fixup right after the app image is assembled, including when it's a step of package* (which build
// the .app then wrap it). finalizedBy ensures it runs even when createDistributable is up-to-date.
tasks.matching { it.name == "createDistributable" || it.name == "createReleaseDistributable" }
    .configureEach { finalizedBy("fixBundledBinaries") }
// package*/dmg/msi/deb wrap the .app into an installer — they must run AFTER the fixup, not race the finalizer.
tasks.matching { it.name.startsWith("package") }.configureEach { mustRunAfter("fixBundledBinaries") }

// ---------------------------------------------------------------------------
// Single localization source of truth.
//
// StarCore/Sources/StarCore/Resources/Localizations is authoritative for every user-visible
// string in every client — the Swift side loads it from its SwiftPM resource bundle, and we
// copy the same JSON tables into this jar at /i18n/ rather than keeping a second copy in git.
// Same reasoning as syncProto below: two copies of a contract drift, one does not.
//
// A checkout without StarCore (the Kotlin client can be built standalone) just gets no tables
// and falls back to showing keys, which is loud enough to notice and not a build failure.
// ---------------------------------------------------------------------------
val localizationsDir = rootProject.file("../StarCore/Sources/StarCore/Resources/Localizations")

tasks.named<ProcessResources>("processResources") {
    if (localizationsDir.isDirectory) {
        from(localizationsDir) {
            into("i18n")
            include("*.json")
        }
    } else {
        logger.warn("processResources: no localization tables at $localizationsDir — " +
                        "the UI will render string keys instead of text")
    }
}

tasks.test {
    useJUnitPlatform()
    // Forward integration-test opt-ins to the test JVM (InteropIntegrationTest no-ops without them).
    for (k in listOf("star.it.config", "star.it.seq", "star.it.process", "star.stard.path")) {
        System.getProperty(k)?.let { systemProperty(k, it) }
    }
}

// Headless engine smoke harness (no spaces in any property value — Gradle's CLI parser otherwise
// mistakes a second word for a task name):
//   ./gradlew smoke -Pseq="/abs/seq"                  # open + Hello + frame 0
//   ./gradlew smoke -Pseq="/abs/seq" -Pmode=process   # also process frames 0..2, confirm previews
tasks.register<JavaExec>("smoke") {
    group = "star"
    description = "Run the headless engine smoke harness against a real stard."
    dependsOn("buildStardRelease") // run the harness against a release daemon, not a slow debug one
    mainClass.set("com.star.desktop.tools.SmokeHarness")
    classpath = sourceSets["main"].runtimeClasspath
    if (project.hasProperty("seq")) {
        val a = mutableListOf(project.property("seq") as String)
        if (project.hasProperty("mode")) a.add(project.property("mode") as String)
        args(a)
    }
}

// ---------------------------------------------------------------------------
// Single proto source of truth.
//
// daemon/proto/star.proto is authoritative for wire content. Our copy differs
// ONLY by the two java_* options codegen needs. `syncProto` regenerates our copy
// from the daemon's; `checkProtoSync` (wired into `check`) fails the build if the
// two ever drift in message/field/enum content, so the wire contract can't rot.
// ---------------------------------------------------------------------------
val daemonProto = rootProject.file("../daemon/proto/star.proto")
val localProto = rootProject.file("proto/star.proto")

fun strippedProtoLines(file: File): List<String> =
    file.readLines().filterNot {
        val t = it.trim()
        t.startsWith("option java_package") || t.startsWith("option java_multiple_files")
    }

tasks.register("syncProto") {
    group = "star"
    description = "Regenerate proto/star.proto from the authoritative daemon copy (adds java_* options)."
    onlyIf { daemonProto.exists() }
    doLast {
        val header = "option swift_prefix = \"Star_V1_\";"
        val out = StringBuilder()
        for (line in daemonProto.readLines()) {
            out.appendLine(line)
            if (line.trim() == header) {
                out.appendLine("option java_package = \"com.star.proto\";")
                out.appendLine("option java_multiple_files = true;")
            }
        }
        localProto.writeText(out.toString())
        println("Synced ${localProto.relativeTo(rootProject.projectDir)} from ${daemonProto.absolutePath}")
    }
}

tasks.register("checkProtoSync") {
    group = "verification"
    description = "Fail if proto/star.proto drifts from the authoritative daemon copy (ignoring java_* options)."
    onlyIf { daemonProto.exists() }
    doLast {
        val a = strippedProtoLines(localProto)
        val b = daemonProto.readLines()
        if (a != b) {
            throw GradleException(
                "proto drift detected between proto/star.proto and ${daemonProto.absolutePath}. " +
                    "Run ./gradlew syncProto to reconcile."
            )
        }
    }
}

tasks.named("check") { dependsOn("checkProtoSync") }
