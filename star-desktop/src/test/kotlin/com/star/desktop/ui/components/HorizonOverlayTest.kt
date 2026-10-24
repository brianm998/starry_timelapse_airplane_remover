package com.star.desktop.ui.components

import com.star.desktop.ui.theme.StarColors
import com.star.proto.HorizonOverlayKind
import kotlin.test.Test
import kotlin.test.assertEquals

/** The colours of a frame's horizon line, as macOS draws it on the frame, the filmstrip and the grid. */
class HorizonOverlayTest {
    @Test fun aPaintedReferenceIsGreenAMergedHorizonBlueAndADetectedOneWhite() {
        assertEquals(StarColors.green, horizonLineColor(HorizonOverlayKind.HORIZON_OVERLAY_KIND_REFERENCE, pending = false))
        assertEquals(StarColors.blue, horizonLineColor(HorizonOverlayKind.HORIZON_OVERLAY_KIND_MERGED, pending = false))
        assertEquals(StarColors.white, horizonLineColor(HorizonOverlayKind.HORIZON_OVERLAY_KIND_INITIAL, pending = false))
    }

    /** The consensus line is what a moving sequence's output uses, so it must not pass for a merged one. */
    @Test fun aHorizonConsensusIsPurple() {
        assertEquals(StarColors.purple, horizonLineColor(HorizonOverlayKind.HORIZON_OVERLAY_KIND_CONSENSUS, pending = false))
    }

    /** Pending wins over the kind: the line shown is the one the user is about to have redone. */
    @Test fun aFrameWaitingForARefinementIsOrangeWhateverItsLine() {
        for (kind in HorizonOverlayKind.values().filter { it != HorizonOverlayKind.UNRECOGNIZED }) {
            assertEquals(StarColors.orange, horizonLineColor(kind, pending = true), "$kind")
        }
    }
}
