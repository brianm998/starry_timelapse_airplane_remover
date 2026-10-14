package com.star.desktop.ui.windows

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import com.star.desktop.data.BlobSource
import com.star.desktop.i18n.Strings
import com.star.desktop.ui.theme.StarTheme
import com.star.proto.BlobStep
import com.star.proto.BlobStepArg
import com.star.proto.BlobStepsResponse
import com.star.proto.DetectionType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.jetbrains.skia.EncodedImageFormat
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** H9: the Blob Processing window's model, and that the window composes. With `-Dstar.render.dump=<dir>` the picture is written there. */
@OptIn(ExperimentalComposeUiApi::class)
class BlobProcessingWindowTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private fun arg(name: String, value: Double, integer: Boolean) =
        BlobStepArg.newBuilder().setName(name).setValuePresent(true).setValue(value).setIsInteger(integer).setDescription("what $name does").build()

    private fun response(type: DetectionType, editable: Boolean, disabled: Boolean = false) = BlobStepsResponse.newBuilder()
        .setDetectionType(type).setEditable(editable).setDescription("A detection type of its own kind.")
        .addSteps(BlobStep.newBuilder().setKind("findBlobs").setTitle("Initial Blob Detection").setDescription("Finds the blobs.")
            .addArgs(arg("minPixelIntensity", 5000.0, true)).addArgs(arg("startMinContrast", 86.0, false)).setCanDisable(false))
        .addSteps(BlobStep.newBuilder().setKind("frameState").setTitle("Set Frame Processing State").setDescription("filter 1"))
        .addSteps(BlobStep.newBuilder().setKind("smallBlobRemover").setTitle("Small Blob Remover").setDescription("gets rid of dimmer blobs off by themselves")
            .addArgs(arg("minBlobSize", 7.0, true)).setCanDisable(true).setDisabled(disabled))
        .build()

    /** Remembers what it was asked and answers with the steps for the type last asked for. */
    private class FakeSource(val make: (DetectionType, Boolean) -> BlobStepsResponse) : BlobSource {
        val asked = ArrayList<String>()
        var failWith: String? = null
        private var disabled = false
        private fun answer(type: DetectionType): BlobStepsResponse {
            failWith?.let { throw IllegalStateException(it) }
            return make(type, disabled)
        }
        override suspend fun steps(type: DetectionType) = answer(type).also { asked += "steps $type" }
        override suspend fun copyFrom(type: DetectionType) = answer(DetectionType.DETECTION_CUSTOM).also { asked += "copy $type" }
        override suspend fun setArg(stepIndex: Int, name: String, value: Double) = answer(DetectionType.DETECTION_CUSTOM).also { asked += "set $stepIndex $name $value" }
        override suspend fun setDisabled(stepIndex: Int, disabled: Boolean): BlobStepsResponse {
            this.disabled = disabled
            return answer(DetectionType.DETECTION_CUSTOM).also { asked += "disable $stepIndex $disabled" }
        }
    }

    private fun model(source: BlobSource) = BlobProcessingModel(CoroutineScope(SupervisorJob() + Dispatchers.Unconfined), source)

    @Test fun loadingShowsTheStepsTheEngineGave() {
        val source = FakeSource { t, _ -> response(t, editable = t == DetectionType.DETECTION_CUSTOM) }
        val m = model(source)
        assertNull(m.steps.value)
        m.load(DetectionType.DETECTION_MILD)
        assertEquals(3, m.steps.value!!.stepsCount)
        assertEquals(DetectionType.DETECTION_MILD, m.steps.value!!.detectionType)
        assertEquals(listOf("steps DETECTION_MILD"), source.asked)
    }

    @Test fun eachChangeIsMadeByTheEngineAndItsAnswerIsWhatIsShown() {
        val source = FakeSource { t, disabled -> response(t, editable = true, disabled = disabled) }
        val m = model(source)
        m.setArg(0, "minPixelIntensity", 1234.0)
        m.setDisabled(2, true)
        m.copyFrom(DetectionType.DETECTION_MILD)
        assertEquals(listOf("set 0 minPixelIntensity 1234.0", "disable 2 true", "copy DETECTION_MILD"), source.asked)
        assertTrue(m.steps.value!!.getSteps(2).disabled, "the answer to the last disable call carried it")
    }

    @Test fun aRefusalIsShownAndTheStepsStayAsTheyWere() {
        val source = FakeSource { t, _ -> response(t, editable = true) }
        val m = model(source)
        m.load(DetectionType.DETECTION_CUSTOM)
        val before = m.steps.value
        source.failWith = "step 9 has no parameter 'x'"
        m.setArg(9, "x", 1.0)
        assertEquals("step 9 has no parameter 'x'", m.error.value)
        assertEquals(before, m.steps.value)
        source.failWith = null
        m.load(DetectionType.DETECTION_CUSTOM)
        assertNull(m.error.value, "an answer clears the complaint")
    }

    private fun render(name: String, session: Boolean, current: DetectionType, model: BlobProcessingModel, height: Int = 820): org.jetbrains.skia.Bitmap {
        val scene = ImageComposeScene(width = 1100, height = height, density = Density(1f)) {
            StarTheme { BlobProcessingWindowView(session, current, onSelectType = {}, model = model) }
        }
        try {
            scene.render()
            scene.render(50_000_000)
            val image = scene.render(100_000_000)
            System.getProperty("star.render.dump")?.takeIf { it.isNotBlank() }?.let {
                File(it, "$name.png").apply { parentFile.mkdirs() }.writeBytes(image.encodeToData(EncodedImageFormat.PNG)!!.bytes)
            }
            return org.jetbrains.skia.Bitmap.makeFromImage(image)
        } finally {
            scene.close()
        }
    }

    private fun colours(b: org.jetbrains.skia.Bitmap): Int {
        val seen = HashSet<Int>()
        for (y in 0 until b.height step 3) for (x in 0 until b.width step 3) seen += b.getColor(x, y)
        return seen.size
    }

    @Test fun theWindowDrawsTheStepsOfTheCustomType() {
        val m = model(FakeSource { t, d -> response(t, editable = true, disabled = d) })
        m.load(DetectionType.DETECTION_CUSTOM)
        assertTrue(colours(render("blob_custom", true, DetectionType.DETECTION_CUSTOM, m)) > 6)
    }

    @Test fun theWindowDrawsAFixedTypeAndTheCaseOfNoSequence() {
        val m = model(FakeSource { t, _ -> response(t, editable = false) })
        m.load(DetectionType.DETECTION_MILD)
        assertTrue(colours(render("blob_mild", true, DetectionType.DETECTION_MILD, m)) > 6)
        assertNotNull(m.steps.value)
        assertTrue(colours(render("blob_nosession", false, DetectionType.DETECTION_MILD, m, height = 200)) > 3)
    }
}
