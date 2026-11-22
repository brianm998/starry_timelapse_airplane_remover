package com.star.desktop.domain

import com.star.desktop.data.LocalPreferences
import com.star.proto.Warning

/**
 * stard's report that the previous run died during a GPU merge (macOS `ViewModel.reportAbandonedRuns`, which does the same with the shared
 * `useGPUForMerge` preference): the machine-wide GPU merge choice is set to off, so sessions opened from now on start with it off. The warning
 * itself is shown by the banner like any other; the toggle stays in the processing settings, where the user can turn it back on.
 */
object GpuMergeTurnedOff {
    const val KIND = "gpuMergeTurnedOff"

    /** Acts on [warning] if it is this kind; returns whether it did. Any other kind leaves [prefs] alone. */
    fun apply(warning: Warning, prefs: LocalPreferences): Boolean {
        if (warning.kind != KIND) return false
        prefs.setGpu(GpuToggle.MERGE, false)
        return true
    }
}
