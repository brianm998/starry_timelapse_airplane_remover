package com.star.desktop.engine

import com.star.desktop.data.SessionRepository
import com.star.proto.CleanMethod
import com.star.proto.Config
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Integration tests against a REAL `stard` (§8.2/§8.3). They spawn the daemon, so they only run when
 * the relevant fixture is provided; otherwise they no-op (green) so normal CI / `gradle test` stays
 * fast and self-contained:
 *   - `-Dstar.it.config=/abs/config.json`  → cross-client resume + config-interop test (§8.3 gate).
 *   - `-Dstar.it.seq=/abs/sequence`         → RPC smoke against a fresh sequence (§8.2).
 * stard is resolved by DaemonProcess (../daemon/.build/debug/stard from the gradle project, or
 * -Dstar.stard.path / STARD_PATH).
 */
class InteropIntegrationTest {

    private val configPath: String? = System.getProperty("star.it.config")?.takeIf { it.isNotBlank() }
    private val seqPath: String? = System.getProperty("star.it.seq")?.takeIf { it.isNotBlank() }

    /** Spawn a fresh stard, run [block] with a connected client, then shut down. */
    private fun <T> withEngine(block: suspend (StarClient) -> T): T = runBlocking {
        val scope = CoroutineScope(SupervisorJob())
        val engine = EngineState(scope)
        assertTrue(engine.start(), "engine failed to start: ${engine.status.value}")
        try {
            block(engine.client ?: error("no client after start"))
        } finally {
            engine.shutdown()
        }
    }

    /**
     * §8.3 cross-client interop gate (config-compatibility slice): a session described by a config.json
     * must resume identically across independent daemon processes, and the on-disk config format must
     * be stable. (Pixel-identity of rendered output is a separate, fixture+processing-heavy check.)
     */
    @Test
    fun crossClientConfigResume() {
        val cfg = configPath ?: run {
            println("[skip] crossClientConfigResume — set -Dstar.it.config=<config.json>")
            return
        }
        val file = File(cfg)
        assertTrue(file.exists(), "config not found: $cfg")

        val (protoA, diskA) = withEngine { client ->
            val info = client.openConfig(file.absolutePath)
            client.getConfig(info.sessionId) to file.readText()
        }
        // A second, independent daemon process resumes the same config (the cross-client path).
        val (protoB, diskB) = withEngine { client ->
            val info = client.openConfig(file.absolutePath)
            client.getConfig(info.sessionId) to file.readText()
        }

        assertEquals(protoA, protoB, "GetConfig differs across resumes — cross-client resume is not idempotent")
        assertEquals(diskA, diskB, "config.json bytes changed across resume — interop format is not stable")
        assertTrue(protoA.starVersion.isNotEmpty(), "config.starVersion missing (version-mismatch warning would not work)")
        assertTrue(protoA.hasNumberAlignedNeighborFrames(), "expert config field not round-tripped")
    }

    /** §8.2 RPC smoke against a real stard from a fresh sequence: Hello → open → frame/outlier reads → close. */
    @Test
    fun rpcSmokeOnSequence() {
        val seq = seqPath ?: run {
            println("[skip] rpcSmokeOnSequence — set -Dstar.it.seq=<sequence dir>")
            return
        }
        withEngine { client ->
            val hello = client.hello("itest")
            assertTrue(hello.daemonVersion.isNotEmpty(), "Daemon.Hello returned no version")

            val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
                .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).build()
            val info = client.openSequence(File(seq).absolutePath, cfg)
            assertTrue(info.frameCount > 0, "OpenSequence returned no frames")
            assertTrue(info.imageWidth > 0 && info.imageHeight > 0, "OpenSequence returned no image dimensions")

            val frame = client.getFrame(info.sessionId, 0)
            assertEquals(0, frame.frameIndex)

            // Outliers/previews may not exist pre-processing; the calls must not break the connection.
            runCatching { client.listOutliers(info.sessionId, 0) }
            client.closeSession(info.sessionId)
            // Connection still healthy after the round-trip.
            assertTrue(client.listSessions().sessionsCount >= 0)
        }
    }
}
