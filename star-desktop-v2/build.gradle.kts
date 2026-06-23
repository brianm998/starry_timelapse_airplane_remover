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

compose.desktop {
    application {
        mainClass = "com.star.desktop.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "Star"
            packageVersion = "2.0.0"
            description = "Star — Nighttime Timelapse Airplane Remover"
            vendor = "Star"
        }
    }
}

tasks.test {
    useJUnitPlatform()
    // Forward integration-test opt-ins to the test JVM (InteropIntegrationTest no-ops without them).
    for (k in listOf("star.it.config", "star.it.seq", "star.stard.path")) {
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
