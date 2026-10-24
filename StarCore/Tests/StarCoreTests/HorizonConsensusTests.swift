import XCTest
import Foundation
import StarCppBridge
@testable import StarCore

/// A moving sequence's horizon from the consensus of every frame's detection.
///
/// The accuracy in `HorizonConsensus`'s documentation was measured on real sequences far too
/// large for a test; these pin each piece, and the whole on a synthetic pan whose true horizon
/// and true camera motion are known exactly.
final class HorizonConsensusTests: XCTestCase {

    private var harness: FrameHarness?

    override func tearDown() {
        harness?.cleanUp()
        harness = nil
        super.tearDown()
    }

    // MARK: - camera rotations

    func testARotationIsRecoveredFromItsOwnHomography() {
        let truth = HorizonConsensus.rotationHomography(f: 900, cx: 600, cy: 400,
                                                        pan: 0.012, tilt: -0.004, roll: 0.002)
        let fit = HorizonConsensus.rotationHomography(matching: truth, width: 1200, height: 800,
                                                      focalLength: 900, bandTop: 500)
        XCTAssertLessThan(fit.rms, 1e-4)
        for (a, b) in zip(fit.homography, truth) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
    }

    /// The reason the stored fits are converted at all: a similarity fitted to a pan over the
    /// ground band is off at the far ends of the frame, and the rotation that matches it in
    /// the band is not.
    func testTheRotationMatchingAPansSimilarityIsRightAcrossTheFrame() {
        let pan = SyntheticPan()
        let truth = pan.trueHomography(from: 4, into: 0)
        let similarity = pan.storedFit(from: 4, into: 0)
        let fit = HorizonConsensus.rotationHomography(matching: similarity, width: pan.width,
                                                      height: pan.height,
                                                      focalLength: pan.focalLength,
                                                      bandTop: pan.bandTop)
        func error(_ h: [Double]) -> Double {
            var worst = 0.0
            for x in stride(from: 0.0, through: Double(pan.width), by: 100) {
                for y in [pan.bandTop, Double(pan.height) - 1] {
                    let a = HorizonConsensus.apply(h, x, y)
                    let b = HorizonConsensus.apply(truth, x, y)
                    worst = max(worst, hypot(a.x - b.x, a.y - b.y))
                }
            }
            return worst
        }
        // Measured: 0.17 px against 1.7 px.  Not zero, see `rotationHomography(matching:)`.
        let rotationError = error(fit.homography), similarityError = error(similarity)
        XCTAssertGreaterThan(similarityError, 1.0,
                             "the synthetic pan should be wide enough for a similarity to miss it")
        XCTAssertLessThan(rotationError, 0.2 * similarityError,
                          "rotation \(rotationError) px, similarity \(similarityError) px")
    }

    func testAFitNoRotationExplainsIsLeftOutOfTheChains() {
        let pan = SyntheticPan()
        let good = pan.storedFit(from: 1, into: 0)
        // a ground fit that shrank the frame by a quarter: no camera rotation does that
        let garbage: [Double] = [0.75, 0, 40, 0, 0.75, 30, 0, 0, 1]
        let converted = HorizonConsensus.rotationRecords([0: [1: good, 2: garbage]],
                                                         width: pan.width, height: pan.height,
                                                         focalLength: pan.focalLength,
                                                         bandTop: pan.bandTop, maxResidual: 6)
        XCTAssertEqual(converted.rejected, 1)
        XCTAssertNotNil(converted.records[0]?[1])
        XCTAssertNil(converted.records[0]?[2])
    }

    // MARK: - chains

    /// Each entry is a translation that says which hop it is, so the composed result says
    /// which path the chain took: 9 to 5 to 1 to 0, the widest hops there are.
    func testChainsTakeTheWidestHopsTowardTheTarget() {
        var records: [Int: [Int: [Double]]] = [:]
        for frame in 0...12 {
            var row: [Int: [Double]] = [:]
            for neighbour in max(0, frame - 4)...min(12, frame + 4) where neighbour != frame {
                // x moves by 1000 per hop, y by the hop's length
                let hop = Double(abs(neighbour - frame))
                row[neighbour] = [1, 0, 1000, 0, 1, hop, 0, 0, 1]
            }
            records[frame] = row
        }
        let chains = HorizonConsensus.chains(into: 0, span: 9, records: records, maxHop: 4)
        let nine = chains[9]
        XCTAssertNotNil(nine)
        XCTAssertEqual(nine?[2] ?? 0, 3000, accuracy: 1e-9, "three hops")
        XCTAssertEqual(nine?[5] ?? 0, 9, accuracy: 1e-9, "of 4, 4 and 1")
        XCTAssertEqual(chains[0] ?? [], HorizonConsensus.identity)
    }

    func testAFrameTheRecordsDoNotReachHasNoChain() {
        let records: [Int: [Int: [Double]]] = [1: [2: HorizonConsensus.identity]]
        let chains = HorizonConsensus.chains(into: 0, span: 3, records: records, maxHop: 1)
        XCTAssertNil(chains[1], "nothing carries frame 1 into frame 0")
        XCTAssertNil(chains[2])
    }

    // MARK: - carrying a line

    func testALineMovesWithTheGround() {
        let width = 1000, height = 800
        let line = [Float](repeating: 600, count: 100)
        var carried = [Float](repeating: 0, count: 100)
        HorizonConsensus.carry(line, by: [1, 0, 0, 0, 1, 30, 0, 0, 1],
                               width: width, height: height, into: &carried)
        for row in carried { XCTAssertEqual(row, 630, accuracy: 1e-3) }

        // moved 200 px right, the line no longer reaches the first fifth of the frame
        HorizonConsensus.carry(line, by: [1, 0, 200, 0, 1, 0, 0, 0, 1],
                               width: width, height: height, into: &carried)
        XCTAssertTrue(carried[0].isNaN)
        XCTAssertTrue(carried[19].isNaN)
        XCTAssertEqual(carried[25], 600, accuracy: 1e-3)
        XCTAssertEqual(carried[99], 600, accuracy: 1e-3)
    }

    func testGridLinesRoundTripThroughFullWidth() {
        var columns: [Int?] = (0..<1200).map { 300 + $0 / 10 }
        // the first grid column is read from full-resolution column 2
        for x in 0..<4 { columns[x] = nil }
        let line = HorizonConsensus.gridLine(fromColumns: columns, height: 800, gridWidth: 300)
        XCTAssertEqual(line.count, 300)
        XCTAssertEqual(line[0], 800, "a column with no ground reads as the height")
        let rows = HorizonConsensus.columnRows(line, width: 1200, height: 800)
        XCTAssertEqual(rows.count, 1200)
        for x in stride(from: 8, to: 1192, by: 37) {
            XCTAssertEqual(Double(rows[x]), Double(300 + x / 10), accuracy: 1.0, "column \(x)")
        }
        XCTAssertEqual(HorizonConsensus.columnRows([800, 800], width: 4, height: 800),
                       [800, 800, 800, 800], "no ground stays no ground")
    }

    // MARK: - the vote

    func testTheDensestWindowWinsAndItsNearestMembersDecide() {
        // twelve far frames agree on 500, four near ones on 430, two strays
        var rows: [Float] = []
        var offsets: [Int] = []
        for k in 0..<12 { rows.append(500 + Float(k % 3) * 0.5); offsets.append(100 + 4 * k) }
        for k in 0..<4 { rows.append(430); offsets.append(4 * (k + 1)) }
        rows += [300, .nan]
        offsets += [8, 12]
        var scratch = HorizonConsensus.VoteScratch()
        let answer = rows.withUnsafeBufferPointer {
            HorizonConsensus.densestWindowRow(rows: $0, offsets: offsets, band: 2,
                                              nearest: 8, scratch: &scratch)
        }
        // the eight nearest of the twelve: 500, 500.5, 501, 500, 500.5, 501, 500, 500.5
        XCTAssertEqual(answer, 500.5, accuracy: 1e-4)
    }

    func testATieGoesToTheTopmostWindow() {
        let rows: [Float] = [400, 400, 600, 600]
        var scratch = HorizonConsensus.VoteScratch()
        let answer = rows.withUnsafeBufferPointer {
            HorizonConsensus.densestWindowRow(rows: $0, offsets: [1, 2, 3, 4], band: 2,
                                              nearest: 8, scratch: &scratch)
        }
        XCTAssertEqual(answer, 400)
    }

    /// The long span replaces the short one only where they disagree by more than chain error
    /// could explain: a cloud bank, not a pixel.
    func testTheLongSpanOverridesOnlyALargeDisagreement() {
        var parameters = HorizonConsensus.Parameters()
        parameters.shortSpan = 10
        parameters.longSpan = 100
        let height = 1000
        let own = [Float](repeating: 400, count: 2)
        // near frames share the cloud top; far ones see the ridge 60 rows lower in column 0
        // and 10 rows lower in column 1
        var carried: [[Float]] = []
        var offsets: [Int] = []
        for k in 1...5 { carried.append([400, 400]); offsets.append(2 * k) }
        for k in 0..<20 { carried.append([460, 410]); offsets.append(20 + 4 * k) }
        var overridden = 0
        let line = HorizonConsensus.consensusLine(own: own, carried: carried, offsets: offsets,
                                                  height: height, parameters: parameters,
                                                  overridden: &overridden)
        XCTAssertEqual(line[0], 460, "60 rows is past 2% of the height")
        XCTAssertEqual(line[1], 400, "10 rows is not")
        XCTAssertEqual(overridden, 1)
    }

    // MARK: - end to end on a synthetic pan

    /// A wide-angle pan across a ridge, with a cloud bank that the per-frame detection reads
    /// as ground for eighty frames.  The focal length is found, and the cloudy frames get the
    /// ridge back.
    func testACloudEpisodeIsCorrectedOnASyntheticPan() throws {
        let pan = SyntheticPan()
        var parameters = HorizonConsensus.Parameters()
        parameters.gridWidth = pan.gridWidth
        // the default sweep's neighbourhood of the true 0.70: the whole sweep costs a minute
        // in a debug build and tests nothing more
        parameters.focalLengthCandidates = [0.61, 0.70, 0.81]
        let lines = pan.detectedLines(cloudy: 120...200)
        let records = pan.storedRecords()

        let cloudy = [130, 160, 190]
        let clear = [40, 260]
        let outcome = try XCTUnwrap(HorizonConsensus.run(
          lines: lines, similarityRecords: records, targets: cloudy + clear,
          width: pan.width, height: pan.height, voterOrigin: 0, parameters: parameters))

        XCTAssertEqual(outcome.calibration.focalLength, pan.focalLength,
                       accuracy: 0.15 * pan.focalLength)
        XCTAssertEqual(outcome.calibration.rejectedEntries, 0)
        XCTAssertEqual(outcome.calibration.distance, 128)

        for frame in cloudy {
            let truth = pan.trueLine(frame: frame)
            let detected = try XCTUnwrap(lines[frame])
            let consensus = try XCTUnwrap(outcome.lines[frame])
            XCTAssertGreaterThan(pan.meanError(detected, truth), 0.01,
                                 "frame \(frame) should start with the cloud read as ground")
            XCTAssertLessThan(pan.meanError(consensus, truth), 0.002, "frame \(frame)")
        }
        for frame in clear {
            let truth = pan.trueLine(frame: frame)
            let consensus = try XCTUnwrap(outcome.lines[frame])
            XCTAssertLessThan(pan.meanError(consensus, truth), 0.002, "frame \(frame)")
        }
    }

    /// The same pan composed from the stored similarities drifts, which is the failure the
    /// rotations are there to remove.
    func testRotationChainsDriftLessThanTheStoredSimilarities() {
        let pan = SyntheticPan()
        let records = pan.storedRecords()
        let rotations = HorizonConsensus.rotationRecords(records, width: pan.width,
                                                         height: pan.height,
                                                         focalLength: pan.focalLength,
                                                         bandTop: pan.bandTop,
                                                         maxResidual: 6).records
        let truth = pan.trueLine(frame: 0)
        let source = pan.trueLine(frame: 200)
        func carriedError(_ records: [Int: [Int: [Double]]]) -> Double {
            let chain = HorizonConsensus.chains(into: 0, span: 200, records: records, maxHop: 4)
            var carried = [Float](repeating: .nan, count: source.count)
            HorizonConsensus.carry(source, by: chain[200]!, width: pan.width,
                                   height: pan.height, into: &carried)
            return pan.meanError(carried, truth)
        }
        let similarityError = carriedError(records)
        let rotationError = carriedError(rotations)
        // Measured at the true focal length: 0.22% of the height over 200 frames, from the
        // fit's small pan bias; the calibrated one does better, see the cloud test.
        XCTAssertLessThan(rotationError, 0.003,
                          "similarity \(similarityError), rotation \(rotationError)")
        XCTAssertGreaterThan(similarityError, 4 * rotationError,
                             "similarity \(similarityError), rotation \(rotationError)")
    }

    func testTooShortASequenceIsNotCalibrated() {
        let pan = SyntheticPan(frameCount: 20)
        let lines = pan.detectedLines(cloudy: nil)
        XCTAssertNil(HorizonConsensus.run(lines: lines, similarityRecords: pan.storedRecords(),
                                          targets: [5], width: pan.width, height: pan.height))
    }

    // MARK: - the store

    func testALineIsStoredAndReadBack() throws {
        var config = Config()
        config.tempOutputPath = FileManager.default.temporaryDirectory
          .appendingPathComponent("HorizonConsensus-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: config.tempOutputPath) }

        let line: [Float] = [10.4, 20.6, .nan, 900]
        try HorizonConsensusStore.write(line: line, frameIndex: 7, width: 64, height: 800,
                                        config: config)
        XCTAssertTrue(HorizonConsensusStore.exists(frameIndex: 7, config: config))
        let record = try XCTUnwrap(HorizonConsensusStore.read(frameIndex: 7, width: 64,
                                                              height: 800, config: config))
        XCTAssertEqual(record.rows, [10, 21, 800, 800], "unknown and off-frame read as no ground")
        XCTAssertNil(HorizonConsensusStore.read(frameIndex: 7, width: 64, height: 600,
                                                config: config),
                     "a line for a frame of another size is not this frame's")
        HorizonConsensusStore.delete(frameIndex: 7, config: config)
        XCTAssertFalse(HorizonConsensusStore.exists(frameIndex: 7, config: config))
    }

    func testPaintedReferencesAreTheMasksNotTheirSettings() throws {
        var config = Config()
        config.tempOutputPath = FileManager.default.temporaryDirectory
          .appendingPathComponent("HorizonConsensus-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: config.tempOutputPath) }
        let directory = try XCTUnwrap(config.dirForImage(ofType: .userHorizon, atSize: .original))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        XCTAssertFalse(HorizonConsensusStore.hasPaintedReferences(config: config))
        // the tuned detector parameters are saved in the same directory
        try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(directory)/horizon_params.json"))
        XCTAssertFalse(HorizonConsensusStore.hasPaintedReferences(config: config))
        let mask = FrameHarness.flatMask(width: 16, height: 16, at: 8)
        XCTAssertTrue(mask.writeTIFFEncoding(toFilename: "\(directory)/LRT_00012.tif"))
        XCTAssertTrue(HorizonConsensusStore.hasPaintedReferences(config: config))
    }

    // MARK: - in the pipeline

    /// The final mask — what the outlier subtraction and the merge composite with — is the
    /// consensus line where there is one, and the merged mask where there is not or where the
    /// user has painted.
    func testTheFinalMaskPrefersTheConsensusLine() async throws {
        let h = try await FrameHarness.make(frameCount: 2, width: 128, height: 96,
                                            horizonRow: 60, named: "consensus-final")
        harness = h
        await h.updateConfig {
            $0.tripodHeadWasMoving = true
            $0.allowEarthAlignment = true
            $0.useHorizonConsensus = true
        }
        try h.plantImage(FrameHarness.flatMask(width: 128, height: 96, at: 60),
                         ofType: .mergedHorizon, frameIndex: 0)
        // hoisted so the closure captures the manager rather than the harness
        let manager = h.configManager
        let config = await MainActor.run { manager.config() }
        try HorizonConsensusStore.write(line: [Float](repeating: 40, count: 32), frameIndex: 0,
                                        width: 128, height: 96, config: config)

        func finalRow() async throws -> Int? {
            await h.frames[0].horizonProcessor.releaseCachedFinalHorizonMask()
            let mask = try await h.frames[0].loadOrCreateFinalHorizonMask()
            let rows = CombinedHorizonDetector.extractHorizonY(from: try XCTUnwrap(mask).image)
            return rows.compactMap { $0 }.sorted().dropFirst(rows.count / 2).first
        }

        let withConsensus = try await finalRow()
        XCTAssertEqual(withConsensus, 40)

        await h.updateConfig { $0.useHorizonConsensus = false }
        let withoutConsensus = try await finalRow()
        XCTAssertEqual(withoutConsensus, 60, "switched off, the merged mask is used")

        await h.updateConfig { $0.useHorizonConsensus = true }
        try h.plantReferenceMask(FrameHarness.flatMask(width: 128, height: 96, at: 70),
                                 perFrame: true, frameIndex: 1)
        let withReferences = try await finalRow()
        XCTAssertEqual(withReferences, 60, "a painted sequence keeps its merged masks")
    }

    /// The op, against a run's leftovers: first-round masks on disk and ground fits in the
    /// homography database, as a moving run leaves them after validation.
    func testTheOpWritesALineForEveryTargetFromWhatARunLeavesOnDisk() async throws {
        // small and short, because standing the frames up is most of this test's cost: 36
        // frames is the fewest the focal length is calibrated from
        let pan = SyntheticPan(width: 320, height: 200, focalLength: 224, frameCount: 36,
                               gridWidth: 160)
        let h = try await FrameHarness.make(frameCount: pan.frameCount, width: pan.width,
                                            height: pan.height, horizonRow: 300,
                                            named: "consensus-op")
        harness = h
        await h.updateConfig {
            $0.tripodHeadWasMoving = true
            $0.allowEarthAlignment = true
            $0.useHorizonConsensus = true
        }
        for frame in 0..<pan.frameCount {
            let rows = pan.trueColumns(frame: frame)
            try h.plantImage(PixelatedImage(mat: PixelatedImageBridge.binaryHorizonMask(
                                width: Int32(pan.width), height: Int32(pan.height),
                                horizonY: rows.map { Optional($0) }))!,
                             ofType: .horizon, frameIndex: frame)
            var warps: [AlignmentWarpInfoCodable] = []
            for neighbour in max(0, frame - 4)...min(pan.frameCount - 1, frame + 4)
            where neighbour != frame {
                let fit = pan.storedFit(from: neighbour, into: frame)
                warps.append(AlignmentWarpInfoCodable(homography: fit,
                                                      deviation: homographyDeviation(fit),
                                                      alignmentState: .homographySuccess,
                                                      frameIndex: neighbour))
            }
            try await h.configManager.homographyDatabase.write(
              frameIndex: frame, type: .earth,
              results: HomographyResultsCodable(for: frame, with: warps))
        }

        var parameters = HorizonConsensus.Parameters()
        parameters.gridWidth = pan.gridWidth
        parameters.focalLengthCandidates = [0.61, 0.70, 0.81]
        let targets = [8, 18, 28]
        let op = HorizonConsensusOp(frames: h.frames, targets: targets,
                                    configManager: h.configManager, rawImageBytes: 0,
                                    parameters: parameters) { error in
            XCTFail("the op reported \(error)")
        }
        try await op.run()

        // hoisted so the closure captures the manager rather than the harness
        let manager = h.configManager
        let config = await MainActor.run { manager.config() }
        for frame in targets {
            let record = try XCTUnwrap(HorizonConsensusStore.read(frameIndex: frame,
                                                                  width: pan.width,
                                                                  height: pan.height,
                                                                  config: config))
            // the stored rows are whole pixels, a quarter of a percent of this height
            XCTAssertLessThan(pan.meanError(record.line, pan.trueLine(frame: frame)), 0.006,
                              "frame \(frame)")
        }
        XCTAssertFalse(HorizonConsensusStore.exists(frameIndex: 9, config: config),
                       "only the targets are written")
        XCTAssertTrue(FileManager.default.fileExists(
                        atPath: HorizonConsensusStore.calibrationPath(config)))
    }
}

/// A camera turning steadily across a fixed ridge: each frame's true horizon, a per-frame
/// "detection" of it, and the ground fits a run would store — 4-DOF similarities fitted to
/// the true motion over the ground band, as `estimateAlignment` makes them.
struct SyntheticPan {
    var width = 1200
    var height = 800
    /// A 24 mm lens on a full-frame sensor, roughly.
    var focalLength = 840.0
    var frameCount = 300
    var gridWidth = 300
    /// Radians the camera turns per frame.
    var panPerFrame = 0.0015

    var bandTop: Double { 0.62 * Double(height) }

    /// The ridge's elevation, in radians above the level, at azimuth `azimuth`.
    func ridge(_ azimuth: Double) -> Double {
        -0.12 + 0.03 * sin(3 * azimuth + 0.4) + 0.012 * sin(11 * azimuth)
    }

    func yaw(_ frame: Int) -> Double { Double(frame) * panPerFrame }

    /// The homography carrying frame `source` into frame `target`.
    func trueHomography(from source: Int, into target: Int) -> [Double] {
        HorizonConsensus.rotationHomography(f: focalLength, cx: Double(width) / 2,
                                            cy: Double(height) / 2,
                                            pan: yaw(target) - yaw(source), tilt: 0, roll: 0)
    }

    /// The row in full-resolution column `x` of `frame` where the sky meets the ridge.
    func trueRow(frame: Int, x: Double) -> Double {
        let cx = Double(width) / 2, cy = Double(height) / 2
        let theta = yaw(frame)
        func skyMinusRidge(_ y: Double) -> Double {
            // camera ray, turned back into the world
            let dx = (x - cx) / focalLength, dy = (y - cy) / focalLength, dz = 1.0
            let wx = cos(theta) * dx - sin(theta) * dz
            let wz = sin(theta) * dx + cos(theta) * dz
            let azimuth = atan2(wx, wz)
            let elevation = atan2(-dy, hypot(wx, wz))
            return elevation - ridge(azimuth)
        }
        var low = 0.0, high = Double(height)
        for _ in 0..<50 {
            let middle = (low + high) / 2
            if skyMinusRidge(middle) > 0 { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    func trueLine(frame: Int) -> [Float] {
        (0..<gridWidth).map { i in
            Float(trueRow(frame: frame,
                          x: HorizonConsensus.gridX(i, width: width, gridWidth: gridWidth)))
        }
    }

    /// The first ground row of every full-resolution column.
    func trueColumns(frame: Int) -> [Int] {
        (0..<width).map { Int(trueRow(frame: frame, x: Double($0)).rounded(.up)) }
    }

    /// Every frame's detection: the true line to the nearest row, except that during `cloudy`
    /// a bank drifting across the middle of the frame reads as ground 6% of the height above
    /// the ridge.
    func detectedLines(cloudy: ClosedRange<Int>?) -> [Int: [Float]] {
        var lines: [Int: [Float]] = [:]
        for frame in 0..<frameCount {
            var line = trueLine(frame: frame).map { $0.rounded() }
            if let cloudy, cloudy.contains(frame) {
                let start = gridWidth * 3 / 10 + (frame - cloudy.lowerBound) / 4
                for i in start..<min(gridWidth, start + gridWidth * 3 / 10) {
                    line[i] -= Float(0.06 * Double(height))
                }
            }
            lines[frame] = line
        }
        return lines
    }

    /// The 4-DOF similarity a run would store for `source` in `target`'s record: the best fit
    /// to the true motion over the ground band.
    func storedFit(from source: Int, into target: Int) -> [Double] {
        let truth = trueHomography(from: source, into: target)
        // least squares for x' = a x - b y + tx, y' = b x + a y + ty
        var normal = [Double](repeating: 0, count: 16)
        var right = [Double](repeating: 0, count: 4)
        for i in 0..<12 {
            for j in 0..<4 {
                let x = Double(width) * (0.03 + 0.94 * Double(i) / 11)
                let y = bandTop + (0.97 * Double(height) - bandTop) * Double(j) / 3
                let moved = HorizonConsensus.apply(truth, x, y)
                for (row, value) in [([x, -y, 1, 0], moved.x), ([y, x, 0, 1], moved.y)] {
                    for r in 0..<4 {
                        for c in 0..<4 { normal[r * 4 + c] += row[r] * row[c] }
                        right[r] += row[r] * value
                    }
                }
            }
        }
        let p = solve4(normal, right)
        return [p[0], -p[1], p[2], p[1], p[0], p[3], 0, 0, 1]
    }

    /// Every frame's record, with its ±4 neighbours.
    func storedRecords() -> [Int: [Int: [Double]]] {
        var records: [Int: [Int: [Double]]] = [:]
        for frame in 0..<frameCount {
            var row: [Int: [Double]] = [:]
            for neighbour in max(0, frame - 4)...min(frameCount - 1, frame + 4)
            where neighbour != frame {
                row[neighbour] = storedFit(from: neighbour, into: frame)
            }
            records[frame] = row
        }
        return records
    }

    /// Mean distance between two grid lines, as a fraction of the height, over the columns
    /// both reach.
    func meanError(_ line: [Float], _ truth: [Float]) -> Double {
        var sum = 0.0, count = 0
        for (a, b) in zip(line, truth) where !a.isNaN && !b.isNaN {
            sum += Double(abs(a - b))
            count += 1
        }
        return count == 0 ? .infinity : sum / Double(count) / Double(height)
    }

    private func solve4(_ a: [Double], _ b: [Double]) -> [Double] {
        var m = a, v = b
        for column in 0..<4 {
            let pivot = (column..<4).max { abs(m[$0 * 4 + column]) < abs(m[$1 * 4 + column]) }!
            if pivot != column {
                for k in 0..<4 { m.swapAt(column * 4 + k, pivot * 4 + k) }
                v.swapAt(column, pivot)
            }
            for row in 0..<4 where row != column {
                let factor = m[row * 4 + column] / m[column * 4 + column]
                for k in 0..<4 { m[row * 4 + k] -= factor * m[column * 4 + k] }
                v[row] -= factor * v[column]
            }
        }
        return (0..<4).map { v[$0] / m[$0 * 4 + $0] }
    }
}
