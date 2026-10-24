package com.star.desktop.ui.components

import com.star.desktop.ui.theme.StarColors
import com.star.proto.GetHorizonOverlayResponse
import com.star.proto.HorizonOverlayKind
import com.star.proto.HorizonOverlayLine
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

    /** The stored names are the macOS app's `HorizonThumbnailOverlay.Kind` raw values, since both apps read the same file. */
    @Test fun eachKindIsStoredUnderTheMacOSName() {
        assertEquals(listOf("initial", "merged", "consensus", "reference"), HorizonLineKinds.all.map { HorizonLineKinds.key(it) })
    }

    @Test fun everyKindIsVisibleUntilHiddenAndAnUnknownNameIsIgnored() {
        assertEquals(HorizonLineKinds.all.toSet(), HorizonLineKinds.visible(emptyList()))
        assertEquals(
            setOf(HorizonOverlayKind.HORIZON_OVERLAY_KIND_INITIAL, HorizonOverlayKind.HORIZON_OVERLAY_KIND_REFERENCE),
            HorizonLineKinds.visible(listOf("merged", "consensus", "somethingNew")),
        )
    }

    /** The kinds a frame has come from its lines; a daemon that sends only the composite's line has only that kind. */
    @Test fun theKindsAFrameHasComeFromItsLines() {
        fun line(kind: HorizonOverlayKind) = HorizonOverlayLine.newBuilder().setKind(kind).addYPerColumn(1).setHeight(2).build()
        val both = GetHorizonOverlayResponse.newBuilder().setExists(true).setKind(HorizonOverlayKind.HORIZON_OVERLAY_KIND_CONSENSUS)
            .addLines(line(HorizonOverlayKind.HORIZON_OVERLAY_KIND_MERGED)).addLines(line(HorizonOverlayKind.HORIZON_OVERLAY_KIND_CONSENSUS))
            .build()
        assertEquals(
            setOf(HorizonOverlayKind.HORIZON_OVERLAY_KIND_MERGED, HorizonOverlayKind.HORIZON_OVERLAY_KIND_CONSENSUS),
            HorizonLineKinds.available(both),
        )
        val old = GetHorizonOverlayResponse.newBuilder().setExists(true).setKind(HorizonOverlayKind.HORIZON_OVERLAY_KIND_MERGED).build()
        assertEquals(setOf(HorizonOverlayKind.HORIZON_OVERLAY_KIND_MERGED), HorizonLineKinds.available(old))
        assertEquals(emptySet(), HorizonLineKinds.available(GetHorizonOverlayResponse.getDefaultInstance()))
        assertEquals(emptySet(), HorizonLineKinds.available(null))
    }
}
