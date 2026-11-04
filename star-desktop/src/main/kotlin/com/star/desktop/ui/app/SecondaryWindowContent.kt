package com.star.desktop.ui.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarTheme
import com.star.desktop.ui.windows.AlignmentWindowView
import com.star.desktop.ui.windows.BlobProcessingWindowView
import com.star.desktop.ui.windows.DebugWindowView
import com.star.desktop.ui.windows.OutlierWindowView

/**
 * The four secondary windows (`Main.kt` shows each in an AWT `Window`) with the size each opens at. The content is here, not in `Main.kt`,
 * so that the parity gallery's runner can draw it: the Compose test host has no AWT window to show it in.
 */
enum class SecondaryWindow(val windowName: String, val size: DpSize) {
    OUTLIER("outlier", DpSize(960.dp, 720.dp)),
    BLOB("blob", DpSize(1100.dp, 800.dp)),
    DEBUG("debug", DpSize(1100.dp, 600.dp)),
    ALIGNMENT("alignment", DpSize(720.dp, 560.dp)),
    ;

    companion object {
        fun named(name: String): SecondaryWindow? = entries.firstOrNull { it.windowName == name }
    }
}

/** What a secondary window shows. [svm] is the open sequence's view model; the outlier and alignment windows are only shown with one. */
@Composable
fun SecondaryWindowContent(kind: SecondaryWindow, vm: AppViewModel, svm: SequenceViewModel?) {
    StarTheme {
        when (kind) {
            SecondaryWindow.OUTLIER -> svm?.let { OutlierWindowView(it) }
            SecondaryWindow.BLOB -> {
                val blobSession by vm.sessions.session.collectAsState()
                BlobProcessingWindowView(
                    session = svm != null,
                    current = blobSession?.config?.detectionType ?: com.star.proto.DetectionType.DETECTION_STRONG,
                    onSelectType = vm::setDetectionType,
                    model = vm.blobProcessing,
                )
            }
            SecondaryWindow.DEBUG -> DebugWindowView(vm.debugLog, vm.engineLogPath)
            SecondaryWindow.ALIGNMENT -> svm?.let { AlignmentWindowView(vm, it) }
        }
    }
}
