package com.star.desktop.domain

import com.star.desktop.i18n.localized
import com.star.proto.StepProgress

/**
 * The line under "Use of this Mac" (macOS `ResourceProfileView`): which resource the governor says is holding the run back. The daemon
 * puts it on the step report (`limited_by`, and `resources_sampled` so that "not limited" is not confused with "not known yet"). The
 * resource's own name ("GPU", "disk X") is StarCore's, as in the gui.
 */
object ResourceStatus {
    /** The line to show, or null when there is no run reporting or the governor has not sampled the machine yet. */
    fun text(report: StepProgress?): String? = when {
        report == null || !report.resourcesSampled -> null
        report.limitedBy.isEmpty() -> localized("ui.use_status_none")
        else -> localized("ui.use_status_limited", report.limitedBy)
    }
}
