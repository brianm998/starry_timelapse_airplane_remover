package com.star.desktop.domain

import com.star.proto.Config

/**
 * The three GPU toggles as the user last set them on this machine, kept in `~/.star.userprefs.json` under the keys the macOS app uses
 * (`UserPreferences.useGPUForMerge` / `useGPUForSIFT` / `useGPUForAKAZE`).
 *
 * Whether a machine's GPU is worth using is a fact about the machine, not about the sequence being processed, so a toggle turned off stays off for
 * every sequence opened afterwards; each sequence's own `config.json` still records the value it ran with. A toggle the user has never touched is
 * not stored at all, which leaves the sequence's own config (on wherever a GPU is available) in charge.
 */
enum class GpuToggle(val key: String, private val read: (Config) -> Boolean, private val has: (Config) -> Boolean, private val write: (Config.Builder, Boolean) -> Unit) {
    /** `Config.useGPUForMerge`; its proto field kept the name `use_gpu_acceleration`. */
    MERGE("useGPUForMerge", { it.useGpuAcceleration }, { it.hasUseGpuAcceleration() }, { b, v -> b.setUseGpuAcceleration(v) }),
    SIFT("useGPUForSIFT", { it.useGpuForSift }, { it.hasUseGpuForSift() }, { b, v -> b.setUseGpuForSift(v) }),
    AKAZE("useGPUForAKAZE", { it.useGpuForAkaze }, { it.hasUseGpuForAkaze() }, { b, v -> b.setUseGpuForAkaze(v) });

    /** The toggle's value in [config], or null when the daemon that sent it predates the field. */
    fun valueIn(config: Config): Boolean? = if (has(config)) read(config) else null

    internal fun set(builder: Config.Builder, value: Boolean) = write(builder, value)

    companion object {
        /**
         * What to send so that [session]'s GPU toggles agree with [chosen], the user's stored choices: the toggles that differ, or null when there is
         * nothing to change. A toggle the user never chose, or one the daemon does not have, is left alone. Only what changes is sent, as the settings
         * sheet does, so no other setting is marked as chosen by the user (the keypoint divisor would be) -- except the four that `Sequence.UpdateConfig`
         * reads every time whether sent or not, which go back as they stand rather than as the proto's zeros.
         */
        fun changesToMatch(chosen: (GpuToggle) -> Boolean?, session: Config): Config? {
            val b = Config.newBuilder()
                .setCleanMethod(session.cleanMethod)
                .setDetectionType(session.detectionType)
                .setHorizonDetectionEnabled(session.horizonDetectionEnabled)
                .setTripodHeadWasMoving(session.tripodHeadWasMoving)
            var any = false
            for (toggle in entries) {
                val want = chosen(toggle) ?: continue
                val have = toggle.valueIn(session) ?: continue
                if (want != have) { toggle.set(b, want); any = true }
            }
            return if (any) b.build() else null
        }

        /** The toggles whose value differs between [before] and [after], with the value they now have: what the user changed, to be remembered. */
        fun changed(before: Config, after: Config): Map<GpuToggle, Boolean> = buildMap {
            for (toggle in GpuToggle.entries) {
                val was = toggle.valueIn(before) ?: continue
                val now = toggle.valueIn(after) ?: continue
                if (was != now) put(toggle, now)
            }
        }
    }
}
