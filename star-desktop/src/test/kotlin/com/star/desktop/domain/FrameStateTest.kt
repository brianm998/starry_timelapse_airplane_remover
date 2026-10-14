package com.star.desktop.domain

import com.star.proto.FrameProcessingState
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class FrameStateTest {
    @Test fun aFrameBeingWorkedOnCounts() {
        for (s in listOf(
            FrameProcessingState.FPS_HORIZON_DETECTION, FrameProcessingState.FPS_STAR_KEYPOINTS, FrameProcessingState.FPS_STAR_ALIGNMENT_ALIGNING,
            FrameProcessingState.FPS_DETECTING_BLOBS, FrameProcessingState.FPS_FILTER_3, FrameProcessingState.FPS_FIRST_CLASSIFICATION,
            FrameProcessingState.FPS_SECOND_CLASSIFICATION, FrameProcessingState.FPS_LOADING_IMAGES, FrameProcessingState.FPS_WRITING_OUTPUT_FILE,
            FrameProcessingState.FPS_FINISHING,
        )) assertTrue(FrameState.isWorking(s), "$s")
    }

    /** Untouched, finished, and waiting for the next stage are not being worked on. */
    @Test fun aFrameAtRestDoesNotCount() {
        for (s in listOf(
            FrameProcessingState.FPS_UNPROCESSED, FrameProcessingState.FPS_HORIZON_DETECTED, FrameProcessingState.FPS_STAR_KEYPOINTS_FOUND,
            FrameProcessingState.FPS_STAR_ALIGNMENT_COMPLETE, FrameProcessingState.FPS_READY_FOR_INTER_FRAME,
            FrameProcessingState.FPS_OUTLIER_PROCESSING_COMPLETE, FrameProcessingState.FPS_USER_MODIFIED, FrameProcessingState.FPS_COMPLETE,
        )) assertFalse(FrameState.isWorking(s), "$s")
    }
}
