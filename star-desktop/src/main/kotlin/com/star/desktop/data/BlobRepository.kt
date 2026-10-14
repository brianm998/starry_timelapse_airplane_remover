package com.star.desktop.data

import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StarRpcException
import com.star.desktop.i18n.localized
import com.star.proto.BlobStepArgChange
import com.star.proto.BlobStepDisabledChange
import com.star.proto.BlobStepsResponse
import com.star.proto.DetectionType
import com.star.proto.SetCustomBlobStepsRequest

/** Where the Blob Processing window gets its steps, and whom it tells of a change to the custom type; every answer is the steps as they now are. */
interface BlobSource {
    suspend fun steps(type: DetectionType): BlobStepsResponse

    /** Replace the custom type's steps with a copy of [type]'s. */
    suspend fun copyFrom(type: DetectionType): BlobStepsResponse

    suspend fun setArg(stepIndex: Int, name: String, value: Double): BlobStepsResponse

    suspend fun setDisabled(stepIndex: Int, disabled: Boolean): BlobStepsResponse
}

/** The blob processing steps, from the engine. */
class BlobRepository(private val clientProvider: () -> StarClient?) : BlobSource {
    private fun c(): StarClient = clientProvider() ?: throw StarRpcException(-1, localized("ui.engine_not_connected"))

    override suspend fun steps(type: DetectionType): BlobStepsResponse = c().getBlobSteps(type)

    override suspend fun copyFrom(type: DetectionType): BlobStepsResponse =
        c().setCustomBlobSteps(SetCustomBlobStepsRequest.newBuilder().setCopyFrom(type).build())

    override suspend fun setArg(stepIndex: Int, name: String, value: Double): BlobStepsResponse =
        c().setCustomBlobSteps(
            SetCustomBlobStepsRequest.newBuilder()
                .setArg(BlobStepArgChange.newBuilder().setStepIndex(stepIndex).setArgName(name).setValue(value))
                .build(),
        )

    override suspend fun setDisabled(stepIndex: Int, disabled: Boolean): BlobStepsResponse =
        c().setCustomBlobSteps(
            SetCustomBlobStepsRequest.newBuilder()
                .setDisabled(BlobStepDisabledChange.newBuilder().setStepIndex(stepIndex).setDisabled(disabled))
                .build(),
        )
}
