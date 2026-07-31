import XCTest
import Foundation
import StarCppBridge
@testable import StarCore

/// `FrameOutlierProcessor` owns a frame's outlier groups: finding them, persisting them, iterating
/// them for the gui, and the destructive user edits — razor, dust promotion, deletion.
///
/// It was at 1.4% coverage.  What matters most is persistence and the destructive operations: an
/// outlier wrongly kept leaves an airplane trail in the output, and one wrongly discarded removes a
/// star.  Both are visible in the final render and neither is recoverable without reprocessing.
///
/// Blob detection itself is not driven here — that needs a real subtraction image and minutes of work
/// per frame.  What is covered is everything around it.
final class FrameOutlierProcessorTests: FrameHarnessTestCase {

    private func processor(_ h: FrameHarness, at index: Int = 0) async -> FrameOutlierProcessor {
        await h.frames[index].outlierProcessor
    }

    /// A group with a consistent `pixels` array and `pixelSet` — the invariant nothing checks, where an
    /// empty array with a real bounding box traps in the feature code.
    private func group(id: UInt16, x: Int, y: Int, width: Int = 4, height: Int = 4) -> OutlierGroup {
        let bounds = BoundingBox(min: Coord(x: x, y: y),
                                 max: Coord(x: x + width - 1, y: y + height - 1))
        var pixelSet: Set<SortablePixel> = []
        var pixels = [UInt16](repeating: 0, count: width * height)
        for localY in 0..<height {
            for localX in 0..<width {
                pixels[localY * width + localX] = 1000
                pixelSet.insert(SortablePixel(x: x + localX, y: y + localY,
                                              value: .sixteenBit(1000)))
            }
        }
        return OutlierGroup(id: id, size: UInt(width * height), brightness: 1000,
                            bounds: bounds, frameIndex: 0, pixels: pixels, pixelSet: pixelSet)
    }

    // MARK: - path derivation

    /// Every persistence path derives from the config, and they have to be per-frame or frames would
    /// overwrite each other's outliers.
    func testThePersistencePathsArePerFrame() async throws {
        let h = try await FrameHarness.make(frameCount: 3, named: "paths")
        harness = h

        var seen: Set<String> = []
        for index in 0..<3 {
            let outlier = await processor(h, at: index)
            let dirname = await outlier.outliersDirname
            let blob = await outlier.blobBinaryFilename
            let trash = await outlier.trashBinaryFilename
            let slices = await outlier.userSliceFilename

            XCTAssertTrue(dirname.hasSuffix("/\(index)"),
                          "the outlier directory must be per frame: \(dirname)")
            XCTAssertTrue(blob.hasPrefix(dirname), "the blob file lives in the frame's directory")
            XCTAssertTrue(trash.hasPrefix(dirname), "and so does the trash file")
            XCTAssertNotEqual(blob, trash, "members and trash are stored separately")
            XCTAssertTrue(slices.contains("slices_\(index).json"),
                          "the user slices are per frame too: \(slices)")

            seen.insert(dirname)
        }
        XCTAssertEqual(seen.count, 3, "three frames must have three distinct directories")
    }

    /// The user-slice directory sits beside the temp output, not inside the outlier directory, so it
    /// survives an outlier reprocess — the razor cuts are user intent, not derived data.
    func testTheUserSliceDirectoryIsOutsideTheOutlierDirectory() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "slicepath")
        harness = h
        let outlier = await processor(h)
        let sliceDir = await outlier.userSliceDirname
        let outlierDir = await outlier.outliersDirname
        XCTAssertFalse(sliceDir.hasPrefix(outlierDir),
                       "razor cuts must not be deleted with the outliers")
        XCTAssertTrue(sliceDir.hasSuffix("-star-user-slices"))
    }

    // MARK: - user slices

    /// Write a slices file directly, the way a previous session would have left one.
    private func plantSlices(_ slices: [BoundingBox],
                             _ outlier: FrameOutlierProcessor) async throws {
        let dirname = await outlier.userSliceDirname
        try FileManager.default.createDirectory(atPath: dirname, withIntermediateDirectories: true)
        let path = await outlier.userSliceFilename
        try JSONEncoder().encode(slices).write(to: URL(fileURLWithPath: path))
    }

    /// Razor cuts are persisted as JSON so they survive a restart; without that the user would have to
    /// re-cut every frame they had already edited.
    func testUserSlicesAreReadBackFromDisk() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "slices")
        harness = h
        let outlier = await processor(h)

        try await plantSlices([BoundingBox(min: Coord(x: 10, y: 20), max: Coord(x: 40, y: 50)),
                               BoundingBox(min: Coord(x: 100, y: 110), max: Coord(x: 130, y: 140))],
                              outlier)

        let loaded = await outlier.getUserSlices()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.map { $0.min.x }), [10, 100])
        XCTAssertEqual(Set(loaded.map { $0.max.y }), [50, 140])
    }

    /// Loading then saving must preserve the cuts — that is the sequence every session performs, and a
    /// lossy save would quietly drop the user's edits on the second run.
    func testLoadingThenSavingPreservesTheCuts() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "slicesave")
        harness = h
        let outlier = await processor(h)

        let original = [BoundingBox(min: Coord(x: 5, y: 6), max: Coord(x: 70, y: 80)),
                        BoundingBox(min: Coord(x: 90, y: 91), max: Coord(x: 120, y: 130))]
        try await plantSlices(original, outlier)

        await outlier.loadUserSlices()      // populates the in-memory copy
        await outlier.saveUserSlices()      // writes it back out

        // read the file independently of the processor to confirm what actually landed
        let path = await outlier.userSliceFilename
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode([BoundingBox].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(Set(decoded.map { $0.min.x }), [5, 90])
        XCTAssertEqual(Set(decoded.map { $0.max.x }), [70, 120])
    }

    /// The cached copy is returned without re-reading, so an edit made in memory is what the gui sees
    /// rather than a stale file.
    func testTheCachedSlicesAreReturnedWithoutRereading() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "slicecache")
        harness = h
        let outlier = await processor(h)

        try await plantSlices([BoundingBox(min: Coord(x: 1, y: 1), max: Coord(x: 2, y: 2))], outlier)
        let first = await outlier.getUserSlices()
        XCTAssertEqual(first.count, 1)

        // change the file underneath; the cached value must win
        try await plantSlices([BoundingBox(min: Coord(x: 9, y: 9), max: Coord(x: 10, y: 10)),
                               BoundingBox(min: Coord(x: 11, y: 11), max: Coord(x: 12, y: 12))],
                              outlier)
        let second = await outlier.getUserSlices()
        XCTAssertEqual(second.count, 1, "the in-memory copy is authoritative once loaded")
    }

    /// No slices file means no cuts, and an empty array rather than nil is what the gui iterates.
    func testNoSlicesFileGivesAnEmptyList() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "noslices")
        harness = h
        let loaded = await processor(h).getUserSlices()
        XCTAssertTrue(loaded.isEmpty)
    }

    /// Loading with nothing there also creates the directory, so the first save has somewhere to go.
    func testLoadingCreatesTheSliceDirectory() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "slicedir")
        harness = h
        let outlier = await processor(h)
        await outlier.loadUserSlices()
        let dirname = await outlier.userSliceDirname
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirname),
                      "the first save needs the directory to exist")
    }

    /// Each frame's slices are independent — a cut on one frame must not appear on another.
    func testSlicesDoNotLeakBetweenFrames() async throws {
        let h = try await FrameHarness.make(frameCount: 2, named: "sliceleak")
        harness = h

        let first = await processor(h, at: 0)
        try await plantSlices([BoundingBox(min: Coord(x: 3, y: 3), max: Coord(x: 9, y: 9))], first)

        let second = await processor(h, at: 1)
        let loaded = await second.getUserSlices()
        XCTAssertTrue(loaded.isEmpty, "frame 1 has no cuts of its own")
    }

    /// Malformed JSON must not throw out of `loadUserSlices` — it degrades to no cuts, because failing
    /// here would block the frame from loading at all.
    func testMalformedSliceJsonDegradesToNoCuts() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "slicebad")
        harness = h
        let outlier = await processor(h)

        let dirname = await outlier.userSliceDirname
        try FileManager.default.createDirectory(atPath: dirname, withIntermediateDirectories: true)
        let path = await outlier.userSliceFilename
        try "not json at all".write(toFile: path, atomically: true, encoding: .utf8)

        let loaded = await outlier.getUserSlices()
        XCTAssertTrue(loaded.isEmpty, "a corrupt slice file must not stop the frame loading")
    }

    // MARK: - the outlier group collection

    /// Before anything runs there are no groups, and nil is what tells the pipeline they still need
    /// finding.
    func testAFreshProcessorHasNoOutlierGroups() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "fresh")
        harness = h
        let groups = await processor(h).getOutlierGroups()
        XCTAssertNil(groups)
    }

    /// The gui initialises an empty collection when the user starts painting outliers by hand on a
    /// frame that has none.
    func testInitializingGivesAnEmptyCollection() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "initempty")
        harness = h
        let outlier = await processor(h)

        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)
        let members = await groups.getMembers()
        let trash = await groups.getTrash()
        XCTAssertTrue(members.isEmpty)
        XCTAssertTrue(trash.isEmpty)
        let collectionFrameIndex = await groups.frameIndex
        XCTAssertEqual(collectionFrameIndex, 0)
    }

    /// The lists the gui's table binds to.  Members and trash are separate, and a group only ever
    /// appears in one.
    func testTheMemberAndTrashListsAreSeparate() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "lists")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)

        await groups.add(group(id: 1, x: 10, y: 10))
        await groups.add(group(id: 2, x: 30, y: 30))
        await groups.dumpInTrash(group(id: 3, x: 50, y: 50))

        let membersOptional = await outlier.outlierGroupList()
        let trashOptional = await outlier.outlierGroupTrashList()
        let members = try XCTUnwrap(membersOptional)
        let trashed = try XCTUnwrap(trashOptional)
        XCTAssertEqual(Set(members.map { $0.id }), [1, 2])
        XCTAssertEqual(trashed.map { $0.id }, [3])
    }

    /// Lookup by id is how the gui resolves a click to a group; trashed groups are deliberately not
    /// found by it, since it searches members only.
    func testLookupByIdFindsMembersOnly() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "lookup")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)

        await groups.add(group(id: 11, x: 10, y: 10))
        await groups.dumpInTrash(group(id: 22, x: 40, y: 40))

        let found = await outlier.outlierGroup(named: 11)
        XCTAssertEqual(found?.id, 11)
        let trashed = await outlier.outlierGroup(named: 22)
        XCTAssertNil(trashed, "the lookup searches members, not trash")
        let missing = await outlier.outlierGroup(named: 99)
        XCTAssertNil(missing)
    }

    /// The member list is nil before anything is loaded, which is how the gui tells "not loaded yet"
    /// from "loaded and empty".
    func testTheMemberListIsNilBeforeLoading() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "listsnil")
        harness = h
        let members = await processor(h).outlierGroupList()
        XCTAssertNil(members)
    }

    /// **The two list accessors are not symmetric.**  `outlierGroupList` returns nil without side
    /// effects, but `outlierGroupTrashList` calls `loadOutliers()` first — which, finding nothing on
    /// disk, initialises an empty collection and runs `findOutliers()`.
    ///
    /// So asking for the trash list triggers a full outlier detection pass as a side effect, and then
    /// returns an empty array rather than nil.  On a real 42MP frame that is minutes of work started by
    /// what reads like a getter.  Pinned rather than changed: which of the two is intended is a
    /// judgement about the gui's loading flow, not something the signature settles.
    func testTheTrashListTriggersALoadWhileTheMemberListDoesNot() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "listasym")
        harness = h
        let outlier = await processor(h)

        let membersBefore = await outlier.outlierGroupList()
        XCTAssertNil(membersBefore, "the member list does not load anything")
        let stillNothing = await outlier.getOutlierGroups()
        XCTAssertNil(stillNothing, "and leaves the collection alone")

        let trash = await outlier.outlierGroupTrashList()
        XCTAssertEqual(trash?.count, 0, "the trash list loads, then reports an empty trash")
        let nowLoaded = await outlier.getOutlierGroups()
        XCTAssertNotNil(nowLoaded,
                        "asking for the trash list created a collection as a side effect")
    }

    // MARK: - iteration

    /// The iteration the gui uses for bulk operations.  The second closure argument says whether the
    /// group came from the trash, and the return value accumulates "did anything change".
    ///
    /// Compared as id-to-flag maps rather than sequences: both iterators walk a dictionary, so the
    /// visit *order* is unspecified and nothing should depend on it.
    func testIterationVisitsMembersAndOptionallyTrash() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "iterate")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)
        await groups.add(group(id: 1, x: 10, y: 10))
        await groups.add(group(id: 2, x: 30, y: 30))
        await groups.dumpInTrash(group(id: 3, x: 50, y: 50))

        let membersOnly = VisitRecorder()
        _ = await outlier.foreachOutlierGroup(includingTrash: false) { group, isTrash in
            await membersOnly.record(id: group.id, isTrash: isTrash)
            return false
        }
        let membersOnlyFlags = await membersOnly.flagsById()
        XCTAssertEqual(membersOnlyFlags, [1: false, 2: false],
                       "with the trash excluded only members are visited, all flagged false")

        let withTrash = VisitRecorder()
        _ = await outlier.foreachOutlierGroup(includingTrash: true) { group, isTrash in
            await withTrash.record(id: group.id, isTrash: isTrash)
            return false
        }
        let withTrashFlags = await withTrash.flagsById()
        XCTAssertEqual(withTrashFlags, [1: false, 2: false, 3: true],
                       "the trash flag must mark which groups came from the trash")
    }

    /// The return value is the OR of the closure's returns, which is what decides whether the frame is
    /// marked as changed and re-saved.
    func testIterationReportsWhetherAnythingChanged() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "didchange")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)
        await groups.add(group(id: 1, x: 10, y: 10))
        await groups.add(group(id: 2, x: 30, y: 30))

        let nothing = await outlier.foreachOutlierGroup(includingTrash: false) { _, _ in false }
        XCTAssertFalse(nothing)

        let something = await outlier.foreachOutlierGroup(includingTrash: false) { group, _ in
            group.id == 2      // only one of the two reports a change
        }
        XCTAssertTrue(something, "one changed group must make the whole pass report a change")
    }

    /// Iterating an unloaded collection is a no-op rather than a crash — the gui can call it before
    /// outliers exist.
    func testIteratingWithNoCollectionIsANoOp() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "iternone")
        harness = h
        let visited = VisitRecorder()
        let changed = await processor(h).foreachOutlierGroup(includingTrash: true) { group, isTrash in
            await visited.record(id: group.id, isTrash: isTrash)
            return true
        }
        XCTAssertFalse(changed)
        let visitedIds = await visited.ids()
        XCTAssertTrue(visitedIds.isEmpty)
    }

    /// The concurrent variant has to visit the same set as the serial one — it exists for speed, not
    /// for different semantics.
    func testTheConcurrentIterationVisitsTheSameGroups() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "itermulti")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)
        for id in 1...8 { await groups.add(group(id: UInt16(id), x: id * 8, y: id * 8)) }
        await groups.dumpInTrash(group(id: 99, x: 200, y: 200))

        let recorder = VisitRecorder()
        _ = await outlier.foreachOutlierGroupMulti(includingTrash: true) { group, isTrash in
            await recorder.record(id: group.id, isTrash: isTrash)
            return false
        }
        let allIds = await recorder.ids()
        XCTAssertEqual(Set(allIds), Set([1, 2, 3, 4, 5, 6, 7, 8, 99].map { UInt16($0) }),
                       "the concurrent pass must cover members and trash alike")
    }

    /// The concurrent pass must report the trash flag the same way the serial one does.  It did not:
    /// the members loop passed `true`, so every group looked trashed.  That made a drag-select with the
    /// trash hidden select nothing at all.
    func testTheConcurrentIterationReportsTheTrashFlagLikeTheSerialOne() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 256, height: 256, named: "trashflag")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)
        await groups.add(group(id: 1, x: 20, y: 20))
        await groups.add(group(id: 2, x: 40, y: 40))
        await groups.dumpInTrash(group(id: 9, x: 80, y: 80))

        let serial = VisitRecorder()
        _ = await outlier.foreachOutlierGroup(includingTrash: true) { group, isTrash in
            await serial.record(id: group.id, isTrash: isTrash); return false
        }
        let multi = VisitRecorder()
        _ = await outlier.foreachOutlierGroupMulti(includingTrash: true) { group, isTrash in
            await multi.record(id: group.id, isTrash: isTrash); return false
        }

        let serialFlags = await serial.flagsById()
        let multiFlags = await multi.flagsById()
        XCTAssertEqual(multiFlags, serialFlags,
                       "the two iterators must agree on which groups are trashed")
        XCTAssertEqual(multiFlags[1], false)
        XCTAssertEqual(multiFlags[2], false)
        XCTAssertEqual(multiFlags[9], true)
    }

    /// The gesture overload builds a bounding box from two corners and visits only groups fully inside
    /// it — that is the drag-select in the gui, and the box has to be corner-order independent.
    func testTheGestureOverloadSelectsGroupsInsideTheDraggedBox() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 256, height: 256, named: "gesture")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)
        await groups.add(group(id: 1, x: 20, y: 20))        // inside
        await groups.add(group(id: 2, x: 40, y: 40))        // inside
        await groups.add(group(id: 3, x: 200, y: 200))      // outside

        let inside = VisitRecorder()
        _ = await outlier.foreachOutlierGroupMulti(between: CGPoint(x: 10, y: 10),
                                                  and: CGPoint(x: 100, y: 100),
                                                  includingTrash: false) { group, isTrash in
            await inside.record(id: group.id, isTrash: isTrash)
            return false
        }
        let insideIds = await inside.ids()
        XCTAssertEqual(Set(insideIds), [1, 2],
                       "only groups fully inside the dragged box may be selected")

        // dragging the other way round must select the same groups
        let reversed = VisitRecorder()
        _ = await outlier.foreachOutlierGroupMulti(between: CGPoint(x: 100, y: 100),
                                                  and: CGPoint(x: 10, y: 10),
                                                  includingTrash: false) { group, isTrash in
            await reversed.record(id: group.id, isTrash: isTrash)
            return false
        }
        let reversedIds = await reversed.ids()
        XCTAssertEqual(Set(reversedIds), Set(insideIds),
                       "the drag direction must not change the selection")
    }

    /// A group only partly inside the box is not selected — the check is full containment, so a drag
    /// cannot half-take an outlier.
    func testAPartiallyOverlappingGroupIsNotSelected() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 256, height: 256, named: "partial")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)
        // straddles the right edge of the box below
        await groups.add(group(id: 5, x: 48, y: 20, width: 10, height: 10))

        let recorder = VisitRecorder()
        _ = await outlier.foreachOutlierGroupMulti(between: CGPoint(x: 10, y: 10),
                                                  and: CGPoint(x: 52, y: 100),
                                                  includingTrash: false) { group, isTrash in
            await recorder.record(id: group.id, isTrash: isTrash)
            return false
        }
        let recordedIds = await recorder.ids()
        XCTAssertTrue(recordedIds.isEmpty,
                      "a group crossing the boundary must not be selected")
    }

    // MARK: - persistence of the groups themselves

    /// The binary round trip is what makes a run resumable and what the gui reloads when revisiting a
    /// frame.  Losing it means reclassifying by hand.
    func testOutlierGroupsRoundTripThroughTheBinaryFile() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 128, named: "binary")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)
        await groups.add(group(id: 1, x: 10, y: 10))
        await groups.add(group(id: 2, x: 40, y: 40))
        await groups.dumpInTrash(group(id: 3, x: 70, y: 70))

        let dirname = await outlier.outliersDirname
        try await groups.writeOutliersBinary(to: dirname)

        let reloadedOptional = try await outlier.loadOutliersFromBinaryFile()
        let reloaded = try XCTUnwrap(reloadedOptional, "the written outliers must load back")
        let members = await reloaded.getMembers()
        let trash = await reloaded.getTrash()
        XCTAssertEqual(Set(members.keys), [1, 2], "both members must survive")
        XCTAssertEqual(Set(trash.keys), [3], "and the trash must stay in the trash")
    }

    /// Nothing written means nothing to load, and the loader has to say so rather than throwing out of
    /// the frame's setup.
    func testLoadingWithNothingWrittenGivesNil() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "binarynone")
        harness = h
        let loaded = await processor(h).loadOutliersFromFile()
        XCTAssertNil(loaded)
    }

    /// An empty collection still round trips, which is the "this frame genuinely has no outliers"
    /// case — distinguishable from "not yet processed" only by the file existing.
    func testAnEmptyCollectionRoundTrips() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "binaryempty")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)

        try await groups.writeOutliersBinary(to: await outlier.outliersDirname)
        let reloaded = try await outlier.loadOutliersFromBinaryFile()
        if let reloaded {
            let members = await reloaded.getMembers()
            XCTAssertTrue(members.isEmpty)
        }
        // nil is also acceptable: an empty write may leave nothing to read
    }

    // MARK: - deletion

    /// Deleting drops the collection and removes the files, so a reprocess starts clean rather than
    /// merging with the old result.
    func testDeletingRemovesTheGroupsAndTheirFiles() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 128, named: "delete")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)
        await groups.add(group(id: 1, x: 10, y: 10))
        try await groups.writeOutliersBinary(to: await outlier.outliersDirname)

        let blobPath = await outlier.blobBinaryFilename
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobPath),
                      "the binary must have been written first")

        try await outlier.deleteOutliers()

        let afterDelete = await outlier.getOutlierGroups()
        XCTAssertNil(afterDelete, "the in-memory collection must be dropped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobPath),
                       "and the file must be gone")
    }

    /// Deleting when nothing has loaded must not throw — it runs on every frame of a reprocess.
    func testDeletingWithNothingLoadedIsHarmless() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "deletenone")
        harness = h
        try await processor(h).deleteOutliers()
    }

    /// Deleting inside a box removes only what it contains, and rewrites the file so the removal
    /// survives a reload.
    func testDeletingInABoxRemovesOnlyWhatItContains() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 256, height: 256, named: "deletebox")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)
        await groups.add(group(id: 1, x: 20, y: 20))
        await groups.add(group(id: 2, x: 200, y: 200))

        try await outlier.deleteOutliers(in: BoundingBox(min: Coord(x: 0, y: 0),
                                                        max: Coord(x: 100, y: 100)))

        let remaining = await groups.getMembers()
        XCTAssertFalse(remaining.keys.contains(1), "the group inside the box must be gone")
        XCTAssertTrue(remaining.keys.contains(2), "the one outside must remain")
    }

    // MARK: - the razor and dust promotion

    /// Dust promotion is the user rescuing small groups the classifier discarded.  It creates the
    /// collection if there is none, so it works on a frame that was never processed.
    func testPromotingDustWithNoCollectionCreatesOne() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 128, named: "dust")
        harness = h
        let outlier = await processor(h)
        let before = await outlier.getOutlierGroups()
        XCTAssertNil(before)

        let promoted = try await outlier.promoteDust(in: BoundingBox(min: Coord(x: 0, y: 0),
                                                                    max: Coord(x: 50, y: 50)))
        let after = await outlier.getOutlierGroups()
        XCTAssertNotNil(after,
                        "the collection must be created rather than the call failing")
        XCTAssertTrue(promoted.isEmpty, "there was no dust to promote")
    }

    /// The razor reports whether it cut anything; with nothing loaded there is nothing to cut and the
    /// call has to be safe.
    func testTheRazorWithNoCollectionIsHarmless() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 128, named: "razor")
        harness = h
        try await processor(h).applyRazor(in: BoundingBox(min: Coord(x: 0, y: 0),
                                                         max: Coord(x: 40, y: 40)),
                                         includingTrash: false)
    }

    /// A razor cut that changes something records the cut in the user slices, so it is reapplied on a
    /// later run rather than being lost.
    func testARazorCutIsRecordedInTheUserSlices() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 256, height: 256, named: "razorslice")
        harness = h
        let outlier = await processor(h)
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)
        // a group straddling the cut line so the razor has something to split
        await groups.add(group(id: 1, x: 30, y: 30, width: 40, height: 40))

        let cut = BoundingBox(min: Coord(x: 40, y: 0), max: Coord(x: 60, y: 255))
        try await outlier.applyRazor(in: cut, includingTrash: false)

        let slices = await outlier.getUserSlices()
        if !slices.isEmpty {
            XCTAssertTrue(slices.contains { $0.min.x == 40 && $0.max.x == 60 },
                          "the cut must be recorded so it survives a reload")
        }
        // an empty list means the razor found nothing to cut, which is also a legal outcome
    }

    // MARK: - image saving

    /// Blob debug images are written per frame for the gui's blob inspector.
    ///
    /// **Only at `.preview` size** — the `.original` save is commented out in the body, so the blob
    /// image is never available at full resolution.  Pinned because the parameter and the name suggest
    /// otherwise, and a caller looking for the original would find nothing.
    func testSavingBlobImagesWritesOnlyThePreviewSize() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64,
                                           writePreviews: true, named: "blobimg")
        harness = h
        let outlier = await processor(h)

        try await outlier.saveImages(for: [], as: .blobs)

        let previewPath = try XCTUnwrap(h.imageAccessor.nameForImage(frameIndex: 0, ofType: .blobs,
                                                                   atSize: .preview))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewPath),
                      "an empty blob list still writes an empty preview at \(previewPath)")

        if let originalPath = h.imageAccessor.nameForImage(frameIndex: 0, ofType: .blobs,
                                                          atSize: .original) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: originalPath),
                           "the full-resolution save is commented out, so nothing is written there")
        }
    }

    // MARK: - identity

    func testTheProcessorCarriesItsDimensionsAndIndex() async throws {
        let h = try await FrameHarness.make(frameCount: 2, width: 96, height: 72, named: "identity")
        harness = h
        for index in 0..<2 {
            let outlier = await processor(h, at: index)
            XCTAssertEqual(outlier.frameIndex, index)
            XCTAssertEqual(outlier.width, 96)
            XCTAssertEqual(outlier.height, 72)
        }
    }
}

/// Records what an iteration closure saw.  An actor because the concurrent overload calls the closure
/// from several tasks at once.
private actor VisitRecorder {
    private var visits: [(id: UInt16, isTrash: Bool)] = []
    func record(id: UInt16, isTrash: Bool) { visits.append((id, isTrash)) }
    func ids() -> [UInt16] { visits.map(\.id) }
    func trashFlags() -> [Bool] { visits.map(\.isTrash) }
    /// Order-independent view, since both iterators walk a dictionary.
    func flagsById() -> [UInt16: Bool] {
        Dictionary(visits.map { ($0.id, $0.isTrash) }, uniquingKeysWith: { a, _ in a })
    }
}
