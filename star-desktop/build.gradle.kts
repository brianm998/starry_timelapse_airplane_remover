import com.google.protobuf.gradle.*
import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("jvm") version "2.1.0"
    id("org.jetbrains.compose") version "1.7.3"
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.0"
    id("com.google.protobuf") version "0.9.4"
}

group = "com.star"
version = "1.0.0"

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
}

// Source sets: spec wants src/jvmMain/kotlin — achieved here via custom srcDirs.
sourceSets {
    main {
        kotlin.srcDirs("src/jvmMain/kotlin")
        resources.srcDirs("src/jvmMain/resources")
        proto.srcDir("proto")
    }
    test {
        kotlin.srcDirs("src/jvmTest/kotlin")
    }
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)

    // Proto messages (NO gRPC)
    implementation("com.google.protobuf:protobuf-kotlin-lite:4.28.3")

    // Coroutines (core + Swing dispatcher for Compose Desktop)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.9.0")

    // JSON for LocalPreferences (~/.star.userprefs.json)
    implementation("com.google.code.gson:gson:2.11.0")

    testImplementation(kotlin("test"))
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}

// Protobuf plugin: generate Java lite + Kotlin extension DSL; no gRPC plugin.
protobuf {
    protoc {
        artifact = "com.google.protobuf:protoc:4.28.3"
    }
    generateProtoTasks {
        all().forEach { task ->
            task.builtins {
                // "java" builtin is auto-created by the java plugin; configure the existing one.
                named("java") { option("lite") }
                create("kotlin") { option("lite") }
            }
        }
    }
}

compose.desktop {
    application {
        mainClass = "com.star.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "star-desktop"
            packageVersion = "1.0.0"
            description = "Star — Nighttime Timelapse Airplane Remover"
            vendor = "Star"
        }
    }
}

tasks.test {
    useJUnitPlatform()
}
