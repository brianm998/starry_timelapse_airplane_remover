package com.star.desktop.domain

import com.star.proto.Config

/**
 * "Use of this Mac" (macOS `ResourceProfileView`): the four profiles, and what changing one asks of the daemon.
 */
object ResourceProfiles {
    const val CUSTOM = "custom"

    /** The chips, in order, with their names in the catalogue. */
    val choices: List<Pair<String, String>> = listOf(
        "full" to "ui.use_full", "balanced" to "ui.use_balanced", "light" to "ui.use_light", CUSTOM to "ui.use_custom",
    )

    /** The profile [config] has; Full when it names none. */
    fun profileOf(config: Config?): String = config?.takeIf { it.hasResourceProfile() }?.resourceProfile ?: "full"

    /**
     * What to send to make [profile] the session's. Opening Custom from another profile asks the daemon to start the custom limits as the
     * limits of the profile being left (macOS `makeCustom`): the copy of the config held here has only what they were the last time, and
     * sent back it would be taken for the user's choice.
     */
    fun switchTo(current: Config, profile: String): Config {
        val builder = current.toBuilder().setResourceProfile(profile)
        if (profile == CUSTOM && profileOf(current) != CUSTOM) builder.setStartCustomFromProfile(true)
        return builder.build()
    }
}

/**
 * Every limit behind Custom (macOS `ResourceCustomLimitsView`): the pipeline depth cap and the memory budget, which have fields of their own,
 * and the six the daemon keeps beside them. The ranges are the macOS popover's steppers and sliders, and the daemon's clamps.
 */
data class CustomLimits(
    val pipelineDepth: Int,
    val memoryFraction: Double,
    val cpuWidth: Int,
    val gpuWidth: Int,
    val gpuDutyCycle: Double,
    val diskStreams: Int,
    val qos: String,
    val ioPolicy: String,
) {
    /** [config] with these limits set, each held to its range. */
    fun applyTo(config: Config): Config = config.toBuilder()
        .setNumberOfFramesToProcessConcurrently(pipelineDepth.coerceIn(PIPELINE_DEPTH))
        .setMaxMatMemoryFraction(memoryFraction.coerceIn(MEMORY_FRACTION.start, MEMORY_FRACTION.endInclusive))
        .setCustomCpuWidth(cpuWidth.coerceIn(CPU_WIDTH))
        .setCustomGpuWidth(gpuWidth.coerceIn(GPU_WIDTH))
        .setCustomGpuDutyCycle(gpuDutyCycle.coerceIn(GPU_DUTY_CYCLE.start, GPU_DUTY_CYCLE.endInclusive))
        .setCustomDiskStreamsPerVolume(diskStreams.coerceIn(DISK_STREAMS))
        .setCustomQos(qos)
        .setCustomIoPolicy(ioPolicy)
        .build()

    companion object {
        val PIPELINE_DEPTH = 1..1024
        val MEMORY_FRACTION = 0.1..0.95
        val CPU_WIDTH = 1..256
        val GPU_WIDTH = 1..32
        val GPU_DUTY_CYCLE = 0.05..1.0
        val DISK_STREAMS = 1..16

        /** The thread priorities the popover offers: the daemon's name, and its name in the catalogue. */
        val QOS: List<Pair<String, String>> = listOf(
            "userInitiated" to "ui.use_custom_qos_user_initiated", "utility" to "ui.use_custom_qos_utility", "background" to "ui.use_custom_qos_background",
        )

        /** The disk priorities. */
        val IO_POLICY: List<Pair<String, String>> = listOf(
            "default" to "ui.use_custom_io_default", "utility" to "ui.use_custom_io_utility", "throttle" to "ui.use_custom_io_throttle",
        )

        /** The limits [config] holds now (the daemon sends all of them). */
        fun of(config: Config): CustomLimits = CustomLimits(
            pipelineDepth = config.numberOfFramesToProcessConcurrently.coerceIn(PIPELINE_DEPTH),
            memoryFraction = (if (config.hasMaxMatMemoryFraction()) config.maxMatMemoryFraction else 0.85).coerceIn(MEMORY_FRACTION.start, MEMORY_FRACTION.endInclusive),
            cpuWidth = (if (config.hasCustomCpuWidth()) config.customCpuWidth else 1).coerceIn(CPU_WIDTH),
            gpuWidth = (if (config.hasCustomGpuWidth()) config.customGpuWidth else 1).coerceIn(GPU_WIDTH),
            gpuDutyCycle = (if (config.hasCustomGpuDutyCycle()) config.customGpuDutyCycle else 1.0).coerceIn(GPU_DUTY_CYCLE.start, GPU_DUTY_CYCLE.endInclusive),
            diskStreams = (if (config.hasCustomDiskStreamsPerVolume()) config.customDiskStreamsPerVolume else 1).coerceIn(DISK_STREAMS),
            qos = config.takeIf { it.hasCustomQos() }?.customQos?.takeIf { v -> QOS.any { it.first == v } } ?: QOS.first().first,
            ioPolicy = config.takeIf { it.hasCustomIoPolicy() }?.customIoPolicy?.takeIf { v -> IO_POLICY.any { it.first == v } } ?: IO_POLICY.first().first,
        )
    }
}
