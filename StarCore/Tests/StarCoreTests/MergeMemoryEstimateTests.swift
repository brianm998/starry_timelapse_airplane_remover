import XCTest
@testable import StarCore

/// Regression tests for the merge streaming decision and the reservation that has to
/// describe it.
///
/// The bug these exist for: `mergeStreamingThresholdMB` was 2048, and at 42MP an
/// aligned build needs 9 x 241MB = 2172MB — over the line by 6%. So every merge in a
/// 42MP run streamed on a near miss, which measured 1.8-2.0x slower end to end while
/// saving no peak memory at all (the keypoint phase sets the peak, and it is done
/// before the first merge starts).
///
/// Nothing failed. Nothing logged. The run was just twice as long, which is exactly why
/// this needs a test rather than a comment: the failure mode of getting the threshold
/// wrong is silent in both directions.
///
/// `testDefaultKeepsBothMergesResidentAt42MP` is the direct reproduction — it fails
/// against the old 2048 default and passes against the current one.
final class MergeMemoryEstimateTests: XCTestCase {

    /// A config carrying nothing but the frame geometry the estimates read.
    private func config(megapixels: Double,
                        bytesPerPixel: Int = 6,
                        bitsPerComponent: Int = 16) -> Config {
        var c = Config()
        // 3:2, the aspect of every frame this pipeline is pointed at.
        let height = (megapixels * 1_000_000 / 1.5).squareRoot()
        c.imageHeight = Int(height.rounded())
        c.imageWidth = Int((height * 1.5).rounded())
        c.imageBytesPerPixel = bytesPerPixel
        c.imageBitsPerComponent = bitsPerComponent
        return c
    }

    // MARK: - Which side of the threshold the default lands on

    func testDefaultKeepsBothMergesResidentAt42MP() {
        let c = config(megapixels: 42.2)

        // Both inner merges, at the configured neighbour counts. `+ 1` for the base
        // frame, matching the C++ gate's `count + 1`.
        XCTAssertFalse(c.mergeStreams(sourceCount: c.numberAlignedNeighborFrames + 1),
                       "the aligned build at 42MP is the near miss this default exists "
                       + "to clear — 9 sources is 2172MB against a \(c.mergeStreamingThresholdMB)MB threshold")
        XCTAssertFalse(c.mergeStreams(sourceCount: c.numberStaticNeighborFrames + 1),
                       "the static earth merge at 42MP is 17 sources, 4102MB")
    }

    /// 61MP is the largest current full-frame sensor, and the reason the default is not
    /// merely a little above 42MP's 4102MB.
    func testDefaultKeepsBothMergesResidentAt61MP() {
        let c = config(megapixels: 60.2)
        XCTAssertFalse(c.mergeStreams(sourceCount: c.numberAlignedNeighborFrames + 1))
        XCTAssertFalse(c.mergeStreams(sourceCount: c.numberStaticNeighborFrames + 1))
    }

    /// The feature still has to engage somewhere, or raising the default has quietly
    /// deleted it. Past ~84MP a 17-source static merge no longer fits.
    func testStreamingStillEngagesOnAFrameLargeEnough() {
        let c = config(megapixels: 120)
        XCTAssertTrue(c.mergeStreams(sourceCount: c.numberStaticNeighborFrames + 1),
                      "streaming must still be reachable at some frame size")
    }

    /// 0 is a meaningful value on the wire and in both settings UIs, not "unset".
    func testZeroThresholdNeverStreams() {
        var c = config(megapixels: 500)
        c.mergeStreamingThresholdMB = 0
        XCTAssertFalse(c.mergeStreams(sourceCount: 200),
                       "0 means never stream, at any frame size or source count")
    }

    // MARK: - The reservation has to describe the path actually taken

    /// `ia_median_merge_image_with_filenames` peaks at `count + 2` whole frames on the
    /// all-resident path: the base, every decoded source, and the output that
    /// `medianImageFromMats` allocates while all of them are still live. The reservation
    /// is in units of `workingFrameBytes`, so compare in bytes rather than multiples —
    /// the two differ whenever the source is not 16-bit.
    func testResidentReservationCoversWhatTheStaticMergeHolds() {
        let c = config(megapixels: 42.2)
        let statics = c.numberStaticNeighborFrames

        XCTAssertFalse(c.mergeStreams(sourceCount: statics + 1),
                       "precondition: this test is about the resident path")

        let reserved = c.workingFrameBytes
            * UInt64(c.effectiveMergeMemoryMultiplier(alignedNeighbours: c.numberAlignedNeighborFrames,
                                                      staticNeighbours: statics))
        let held = c.workingFrameBytes * UInt64(statics + 2)

        XCTAssertGreaterThanOrEqual(reserved, held,
                                    "a resident static merge holds \(statics + 2) frames; "
                                    + "reserving less means the ledger under-counts the "
                                    + "path it just chose")
    }

    /// The bonus is charged if and only if a build is resident. Streaming and reserving
    /// for resident wastes concurrency; resident and reserving for streaming costs the
    /// machine.
    func testExtraMultiplierTracksTheStreamingDecision() {
        let resident = config(megapixels: 42.2)
        XCTAssertGreaterThan(resident.residentBuildExtraMultiplier(alignedNeighbours: nil,
                                                                   staticNeighbours: nil),
                             0,
                             "both builds are resident at 42MP, so the bonus must apply")

        var streaming = resident
        streaming.mergeStreamingThresholdMB = 1
        XCTAssertEqual(streaming.residentBuildExtraMultiplier(alignedNeighbours: nil,
                                                             staticNeighbours: nil),
                       0,
                       "everything streams at a 1MB threshold, so nothing extra is held")
        XCTAssertEqual(streaming.effectiveMergeMemoryMultiplier(alignedNeighbours: nil,
                                                               staticNeighbours: nil),
                       streaming.mergeMemoryMultiplier
                         + streaming.concurrentLoadExtraMultiplier,
                       "with nothing resident, a merge should charge the base multiplier "
                       + "and its sources in flight, and nothing else")
    }

    /// The sources in flight are their own term, charged whether or not a build is
    /// resident, because `mergeLoadConcurrency` decides how many of them exist. It has to
    /// vanish at 1 — the serial loop holds one source, which the base multiplier already
    /// covers — and grow with the setting, since that is the memory the setting buys.
    func testSourcesInFlightAreChargedSeparatelyFromTheResidentSet() {
        var c = config(megapixels: 42.2)

        // The shipped default loads one source at a time and so costs nothing here.
        // Measured: raising it made one merge ~1.5x faster in isolation but made no
        // difference to a full 42MP run, because the run is already keeping the machine
        // busy with other frames — so the default does not pay for what it cannot use.
        XCTAssertEqual(Config().mergeLoadConcurrency, 1)
        XCTAssertEqual(c.concurrentLoadExtraMultiplier, 0,
                       "the default must not reserve for workers it does not run")

        c.mergeLoadConcurrency = 1
        XCTAssertEqual(c.concurrentLoadExtraMultiplier, 0,
                       "one worker is the serial loop, which holds nothing extra")
        let serial = c.effectiveMergeMemoryMultiplier(alignedNeighbours: 8, staticNeighbours: 16)

        c.mergeLoadConcurrency = 4
        XCTAssertGreaterThan(c.concurrentLoadExtraMultiplier, 0)
        let concurrent = c.effectiveMergeMemoryMultiplier(alignedNeighbours: 8, staticNeighbours: 16)
        XCTAssertGreaterThan(concurrent, serial,
                             "raising the concurrency has to raise what a merge reserves")

        // and it is not the resident term in disguise: it applies with everything streaming
        c.mergeStreamingThresholdMB = 1
        XCTAssertEqual(c.residentBuildExtraMultiplier(alignedNeighbours: 8, staticNeighbours: 16), 0,
                       "precondition: everything streams at a 1MB threshold")
        XCTAssertGreaterThan(c.effectiveMergeMemoryMultiplier(alignedNeighbours: 8,
                                                             staticNeighbours: 16),
                             c.mergeMemoryMultiplier)

        // a negative setting must not turn into a credit
        c.mergeLoadConcurrency = -3
        XCTAssertEqual(c.concurrentLoadExtraMultiplier, 0)
    }

    /// Raising the threshold is what pays for the resident path, in concurrency rather
    /// than in peak memory: the same op reserves more, and the budget converts that into
    /// fewer merges at once. Pinned because it is the intended cost of this default, and
    /// a change that made raising the threshold free would mean the estimate stopped
    /// following the code.
    func testRaisingTheThresholdRaisesWhatAMergeReserves() {
        let resident = config(megapixels: 42.2)
        var streaming = resident
        streaming.mergeStreamingThresholdMB = 2048   // the old default

        XCTAssertGreaterThan(resident.effectiveMergeMemoryMultiplier(alignedNeighbours: nil,
                                                                     staticNeighbours: nil),
                             streaming.effectiveMergeMemoryMultiplier(alignedNeighbours: nil,
                                                                      staticNeighbours: nil))
    }

    /// A frame near either end of the sequence has fewer neighbours than configured, and
    /// charging for the configured count over-reserves by whole frames. `nil` is the
    /// "could not tell" case and must stay the conservative one.
    func testActualNeighbourCountsReserveLessThanConfigured() {
        let c = config(megapixels: 42.2)
        XCTAssertFalse(c.mergeStreams(sourceCount: c.numberStaticNeighborFrames + 1),
                       "precondition: the counts only change the reservation on the "
                       + "resident path, where the sources are what is held")

        let one = c.effectiveMergeMemoryMultiplier(alignedNeighbours: 1, staticNeighbours: 1)
        let configured = c.effectiveMergeMemoryMultiplier(alignedNeighbours: nil,
                                                          staticNeighbours: nil)
        XCTAssertLessThan(one, configured)

        XCTAssertEqual(c.effectiveMergeMemoryMultiplier(alignedNeighbours: 0, staticNeighbours: 0),
                       c.mergeMemoryMultiplier + c.concurrentLoadExtraMultiplier,
                       "an actual 0 is honoured as 0 — a merge with no sources holds no "
                       + "resident set, whatever its loaders could have been carrying")
    }

    /// An unknown frame size must not silently read as "everything fits". With no
    /// geometry there are no bytes to compare, so nothing streams — and the reservation
    /// then has to be the resident one.
    func testUnknownGeometryReservesForTheResidentPath() {
        let c = Config()   // no imageWidth/Height/bytesPerPixel
        XCTAssertEqual(c.rawImageBytes, 0)
        XCTAssertFalse(c.mergeStreams(sourceCount: c.numberStaticNeighborFrames + 1))
        XCTAssertGreaterThan(c.effectiveMergeMemoryMultiplier(alignedNeighbours: nil,
                                                             staticNeighbours: nil),
                             c.mergeMemoryMultiplier)
    }
}
