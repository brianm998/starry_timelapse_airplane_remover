package com.star.desktop.ui.app

import com.star.desktop.ui.app.PreRenderPromptFlow.Start
import com.star.desktop.ui.app.PreRenderPromptFlow.Step
import com.star.proto.VideoEncodeSettings
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The pre-processing "Render video after processing?" prompt (macOS `PreProcessingRenderFlowTests`): Yes leads to the render options,
 * "Use These Settings" starts processing with auto-render on and the chosen settings, Cancel goes back to the question.
 * `AppViewModel` cannot be built in a test, so the flow it holds is tested on its own.
 */
class PreRenderPromptFlowTest {
    private val chosen = VideoEncodeSettings.newBuilder()
        .setFrameRate(29.97).setCodec("prores").setEncoder("prores_ks").setPixelFormat("yuv444p10le").setMuxer("mov").setOutputHeight(1080).build()

    @Test fun yesThenConfirmStartsWithAutoRenderAndCarriesTheSettings() {
        val flow = PreRenderPromptFlow()
        flow.open()
        assertEquals(Step.ASKING, flow.step.value)

        flow.yes()
        assertEquals(Step.CHOOSING, flow.step.value, "Yes asks how to render; it starts nothing")

        val start = flow.confirm(chosen)
        assertEquals(Start(autoRender = true, dontAskAgain = false, settings = chosen), start)
        assertEquals(1080, start?.settings?.outputHeight, "the resolution is not a preference: it has to travel with the settings")
        assertEquals(Step.CLOSED, flow.step.value)

        // and they are what the question holds for the render at the end of that run
        val question = RenderQuestion()
        question.arm(forRun = 1, render = start!!.autoRender, ask = !start.dontAskAgain, settings = start.settings)
        assertEquals(chosen, question.renderSettings)
    }

    @Test fun cancelInTheOptionsReturnsToThePromptWithoutStarting() {
        val flow = PreRenderPromptFlow()
        flow.open()
        flow.yes()
        flow.cancelOptions()
        assertEquals(Step.ASKING, flow.step.value)
        assertNull(flow.confirm(chosen), "the options are not showing, so there is nothing to confirm")
        assertEquals(Step.ASKING, flow.step.value)

        flow.yes()
        assertEquals(Step.CHOOSING, flow.step.value, "Yes again goes on to the options")
    }

    @Test fun noAndDontAskAgainStartAsBefore() {
        val flow = PreRenderPromptFlow()
        flow.open()
        assertEquals(Start(autoRender = false, dontAskAgain = false), flow.no())
        assertEquals(Step.CLOSED, flow.step.value)

        flow.open()
        assertEquals(Start(autoRender = false, dontAskAgain = true), flow.dontAskAgain())
        assertEquals(Step.CLOSED, flow.step.value)
    }

    @Test fun theViewModelAndDialogsUseIt() {
        fun main(rel: String) = listOf(File("src/main/kotlin/com/star/desktop/$rel"), File("star-desktop/src/main/kotlin/com/star/desktop/$rel")).first { it.isFile }.readText()
        val vm = main("ui/app/AppViewModel.kt")
        assertTrue("preRenderFlow.confirm(settings)" in vm)
        assertTrue("openRenderVideo(autoStart = true, settings = settings)" in vm, "the settings reach the automatic render")
        val prompts = main("ui/dialogs/RenderPromptDialogs.kt")
        val prompt = prompts.substringAfter("fun PreProcessingRenderPrompt(").substringBefore("fun PreRenderOptionsDialog(")
        assertFalse("confirmStartProcessing(autoRender = true" in prompt, "Yes no longer starts processing itself")
        assertTrue("prompt.pre.yes" in prompt && "prompt.pre.no" in prompt)
        assertTrue("prompt.options.confirm" in prompts)
    }
}
