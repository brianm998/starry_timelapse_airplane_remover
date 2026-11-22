package com.star.desktop.ui.dialogs

/**
 * The output JPEG quality row of the processing settings (`Config.output_jpeg_quality`; macOS `ImageSequenceViewModel.outputJPEGQuality`).
 * The slider starts at the quality of the input frames (`SessionInfo.source_jpeg_quality`) and moving it overrides that; 0 is "same as the input".
 */
internal object OutputQuality {
    const val MIN = 1
    const val MAX = 100

    /** Only JPEG sequences have an input quality to start from (`source_jpeg_quality` is 0 for anything else). */
    fun visible(sourceQuality: Int): Boolean = sourceQuality in MIN..MAX

    /** What the slider shows: the override, else the input's. */
    fun shown(chosen: Int, sourceQuality: Int): Int = if (chosen in MIN..MAX) chosen else sourceQuality

    /** The note "Same as the input" is shown while the outputs follow the input's quality. */
    fun matchesInput(chosen: Int, sourceQuality: Int): Boolean = shown(chosen, sourceQuality) == sourceQuality

    /** The override a slider position means: landing on the input's own quality is no override at all (0). */
    fun overrideFor(position: Int, sourceQuality: Int): Int {
        val q = position.coerceIn(MIN, MAX)
        return if (q == sourceQuality) 0 else q
    }
}
