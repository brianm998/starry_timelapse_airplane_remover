import XCTest
import StarCppBridge
@testable import StarCore

/// `OutlierGroups` is a frame's collection of outliers, split into `members` (still candidates) and
/// `trash` (rejected), plus the row-major id image the overlap features are computed from.  556
/// lines, none of it covered.
///
/// The interesting parts are the boundaries between those three pieces: what happens to an id that
/// is in both, what the id image does when a member and a trashed group overlap, and whether a new
/// group can be handed an id that trash still holds.
final class OutlierGroupsTests: XCTestCase {

    private func config(width: Int = 100, height: Int = 80) -> Config {
        var config = Config()
        config.imageWidth = width
        config.imageHeight = height
        return config
    }

    /// A group whose `pixels` array, `pixelSet` and `bounds` all agree — see the note in
    /// OutlierGroupFeatureTests about that being one unchecked invariant.
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
                            bounds: bounds, frameIndex: 0,
                            imageWidth: 1000, imageHeight: 500,
                            pixels: pixels, pixelSet: pixelSet)
    }

    private func groups(_ config: Config? = nil) -> OutlierGroups {
        OutlierGroups(frameIndex: 0, config: config ?? self.config())
    }

    // MARK: - membership

    func testAFreshCollectionIsEmpty() async {
        let outliers = groups()
        let members = await outliers.getMembers()
        let trash = await outliers.getTrash()
        XCTAssertTrue(members.isEmpty)
        XCTAssertTrue(trash.isEmpty)
    }

    func testAnAddedGroupIsFoundByItsId() async {
        let outliers = groups()
        await outliers.add(group(id: 7, x: 10, y: 10))

        let found = await outliers.get(with: 7)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, 7)
        let absent = await outliers.get(with: 8)
        XCTAssertNil(absent)
    }

    func testAddingManyGroupsKeepsThemAllApart() async {
        let outliers = groups()
        await outliers.add((1...5).map { group(id: UInt16($0), x: $0 * 10, y: 10) })

        let members = await outliers.getMembers()
        XCTAssertEqual(members.count, 5)
        for id in UInt16(1)...5 { XCTAssertEqual(members[id]?.id, id) }
    }

    /// Keyed by id, so re-adding an id replaces rather than accumulating.
    func testAddingTheSameIdTwiceReplaces() async {
        let outliers = groups()
        await outliers.add(group(id: 3, x: 10, y: 10))
        await outliers.add(group(id: 3, x: 50, y: 50))

        let members = await outliers.getMembers()
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members[3]?.bounds.min, Coord(x: 50, y: 50),
                       "the later group should have won")
    }

    // MARK: - trash

    func testTrashingAGroupMovesItOutOfTheMembers() async {
        let outliers = groups()
        let doomed = group(id: 4, x: 10, y: 10)
        await outliers.add(doomed)
        await outliers.dumpInTrash([doomed])

        let members = await outliers.getMembers()
        let trash = await outliers.getTrash()
        XCTAssertTrue(members.isEmpty, "a trashed group should leave the members")
        XCTAssertEqual(trash[4]?.id, 4)
        let gone = await outliers.get(with: 4)
        XCTAssertNil(gone, "get only looks at members")
    }

    func testPromotingFromTrashMovesItBack() async {
        let outliers = groups()
        let group = group(id: 4, x: 10, y: 10)
        await outliers.dumpInTrash([group])
        await outliers.promoteFromTrash(group)

        let members = await outliers.getMembers()
        let trash = await outliers.getTrash()
        XCTAssertEqual(members[4]?.id, 4)
        XCTAssertTrue(trash.isEmpty, "promoting should take it out of the trash")
    }

    func testTrashingAndPromotingRoundTrips() async {
        let outliers = groups()
        let group = group(id: 9, x: 20, y: 20)
        await outliers.add(group)

        for _ in 0..<3 {
            await outliers.dumpInTrash([group])
            await outliers.promoteFromTrash(group)
        }

        let members = await outliers.getMembers()
        let trash = await outliers.getTrash()
        XCTAssertEqual(members.count, 1)
        XCTAssertTrue(trash.isEmpty)
    }

    /// Adding the array form takes the id back out of the trash, so a group cannot be in both.
    func testTheArrayAddTakesAnIdBackOutOfTheTrash() async {
        let outliers = groups()
        let group = group(id: 5, x: 10, y: 10)
        await outliers.dumpInTrash([group])
        await outliers.add([group])

        let members = await outliers.getMembers()
        let trash = await outliers.getTrash()
        XCTAssertEqual(members[5]?.id, 5)
        XCTAssertTrue(trash.isEmpty)
    }

    /// The single-group `add` does *not* — unlike the array form and unlike `promoteFromTrash`, it
    /// leaves the trash entry in place, so the group ends up in both collections at once.  Pinned
    /// because the asymmetry between the two overloads is invisible at the call site.
    func testTheSingleAddLeavesATrashEntryBehind() async {
        let outliers = groups()
        let group = group(id: 5, x: 10, y: 10)
        await outliers.dumpInTrash([group])
        await outliers.add(group)               // the single-group overload

        let members = await outliers.getMembers()
        let trash = await outliers.getTrash()
        XCTAssertEqual(members[5]?.id, 5)
        XCTAssertEqual(trash[5]?.id, 5,
                       "if this is now empty, add(_:) was made to match add([_]) — update this test")
    }

    // MARK: - maxID

    func testMaxIdIsTheLargestMemberId() async {
        let outliers = groups()
        await outliers.add([group(id: 3, x: 10, y: 10),
                            group(id: 17, x: 20, y: 10),
                            group(id: 9, x: 30, y: 10)])
        let max = await outliers.maxID
        XCTAssertEqual(max, 17)
    }

    func testMaxIdOfAnEmptyCollectionIsZero() async {
        let max = await groups().maxID
        XCTAssertEqual(max, 0)
    }

    /// `maxID` scans only the members, so an id that trash still holds is not counted.  Anything
    /// allocating new ids from `maxID + 1` can therefore hand out an id trash is using, which would
    /// then collide in the id image below.  Pinned rather than endorsed.
    func testMaxIdIgnoresIdsHeldByTheTrash() async {
        let outliers = groups()
        await outliers.add([group(id: 3, x: 10, y: 10)])
        await outliers.dumpInTrash([group(id: 99, x: 50, y: 50)])

        let max = await outliers.maxID
        XCTAssertEqual(max, 3, "if this is now 99, maxID was made to include the trash")
    }

    // MARK: - the id image

    /// The id image is row-major and holds each pixel's outlier id, which is what the overlap
    /// features are computed from.  Zero means no outlier there.
    func testTheIdImageLabelsEachGroupsPixelsWithItsId() async {
        let outliers = groups()
        await outliers.add([group(id: 11, x: 10, y: 10, width: 3, height: 3)])
        await outliers.calculateOutlierImageData()

        let data = await outliers.outlierImageDataFunc()
        XCTAssertEqual(data.count, 100 * 80)

        for y in 10..<13 {
            for x in 10..<13 {
                XCTAssertEqual(data[y * 100 + x], 11, "pixel [\(x), \(y)]")
            }
        }
        XCTAssertEqual(data[0], 0, "a pixel no group covers stays zero")
        XCTAssertEqual(data[9 * 100 + 9], 0)
    }

    func testTwoGroupsGetTheirOwnLabels() async {
        let outliers = groups()
        await outliers.add([group(id: 1, x: 5, y: 5, width: 2, height: 2),
                            group(id: 2, x: 50, y: 40, width: 2, height: 2)])
        await outliers.calculateOutlierImageData()

        let data = await outliers.outlierImageDataFunc()
        XCTAssertEqual(data[5 * 100 + 5], 1)
        XCTAssertEqual(data[40 * 100 + 50], 2)
    }

    /// Trashed groups are labelled too, and they are written *after* the members — so where a
    /// trashed group overlaps a member, the trash id is what the image reports.  That matters for
    /// `groups(overlapping:)` below.
    func testTrashedGroupsAreAlsoLabelledAndWinAnyOverlap() async {
        let outliers = groups()
        await outliers.add([group(id: 1, x: 10, y: 10, width: 4, height: 4)])
        await outliers.dumpInTrash([group(id: 2, x: 10, y: 10, width: 4, height: 4)])
        await outliers.calculateOutlierImageData()

        let data = await outliers.outlierImageDataFunc()
        XCTAssertEqual(data[10 * 100 + 10], 2,
                       "the trashed group is written last, so its id wins the overlap")
    }

    /// The id image is only as big as the frame, and a group's pixels outside it are skipped rather
    /// than trapping — the bounds check in `calculateOutlierImageData` exists for that.
    func testPixelsOutsideTheFrameAreSkippedRatherThanTrapping() async {
        let outliers = groups(config(width: 20, height: 20))
        // a group hanging off the bottom right corner
        await outliers.add([group(id: 1, x: 18, y: 18, width: 5, height: 5)])
        await outliers.calculateOutlierImageData()

        let data = await outliers.outlierImageDataFunc()
        XCTAssertEqual(data.count, 400)
        XCTAssertEqual(data[18 * 20 + 18], 1, "the part inside the frame is still labelled")
    }

    func testReleasingTheIdImageFreesIt() async {
        let outliers = groups()
        await outliers.add([group(id: 1, x: 10, y: 10)])
        await outliers.calculateOutlierImageData()
        await outliers.releaseOutlierImageData()

        let data = await outliers.outlierImageData
        XCTAssertTrue(data.isEmpty, "releasing should drop the buffer")
    }

    func testSettingTheIdImageDirectlyReplacesIt() async {
        let outliers = groups()
        var supplied = [UInt16](repeating: 0, count: 100 * 80)
        supplied[500] = 42
        await outliers.set(outlierImageData: supplied)

        let data = await outliers.outlierImageDataFunc()
        XCTAssertEqual(data[500], 42)
    }

    // MARK: - overlap queries

    /// `groups(overlapping:)` is how the inter-frame features find what a group sits on top of.
    func testAGroupOverlappingAMemberFindsIt() async {
        let outliers = groups()
        await outliers.add([group(id: 1, x: 10, y: 10, width: 6, height: 6)])

        // a probe sitting squarely on top of it
        let probe = group(id: 99, x: 12, y: 12, width: 2, height: 2)
        let found = await outliers.groups(overlapping: probe)

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.id, 1)
    }

    func testAGroupOverlappingNothingFindsNothing() async {
        let outliers = groups()
        await outliers.add([group(id: 1, x: 10, y: 10, width: 4, height: 4)])

        let probe = group(id: 99, x: 60, y: 60, width: 2, height: 2)
        let found = await outliers.groups(overlapping: probe)
        XCTAssertTrue(found.isEmpty)
    }

    func testAGroupOverlappingSeveralMembersFindsThemAll() async {
        let outliers = groups()
        await outliers.add([group(id: 1, x: 10, y: 10, width: 2, height: 2),
                            group(id: 2, x: 12, y: 10, width: 2, height: 2)])

        // a probe spanning both
        let probe = group(id: 99, x: 10, y: 10, width: 4, height: 2)
        let found = await outliers.groups(overlapping: probe)

        XCTAssertEqual(Set(found.map(\.id)), [1, 2])
    }

    /// The consequence of trash being labelled: where a trashed group covers a member, the id image
    /// reports the trashed id, and `groups(overlapping:)` looks that up in `members` — finding
    /// nothing.  So the member underneath is not reported as overlapping.  Pinned because it is
    /// silent: the assignment of a nil simply removes the key.
    func testAMemberHiddenUnderATrashedGroupIsNotReportedAsOverlapping() async {
        let outliers = groups()
        await outliers.add([group(id: 1, x: 10, y: 10, width: 4, height: 4)])
        await outliers.dumpInTrash([group(id: 2, x: 10, y: 10, width: 4, height: 4)])

        let probe = group(id: 99, x: 11, y: 11, width: 2, height: 2)
        let found = await outliers.groups(overlapping: probe)

        XCTAssertTrue(found.isEmpty,
                      "the member is masked by the trashed group's label — if this now finds "
                      + "group 1, the id image or the lookup was changed")
    }

    /// `groups(nearby:within:)` widens the search to a radius, which is what
    /// `numberOfNearbyOutliersInSameFrame` counts.
    func testNearbyFindsAGroupWithinTheSearchDistance() async {
        let outliers = groups()
        await outliers.add([group(id: 1, x: 30, y: 30, width: 2, height: 2)])

        let probe = group(id: 99, x: 36, y: 30, width: 2, height: 2)
        let near = await outliers.groups(nearby: probe, within: 20)
        XCTAssertEqual(near.map(\.id), [1])

        let far = await outliers.groups(nearby: probe, within: 1)
        XCTAssertTrue(far.isEmpty, "a one pixel radius should not reach six pixels away")
    }

    func testNearbyWidensMonotonically() async {
        let outliers = groups()
        await outliers.add([group(id: 1, x: 30, y: 30, width: 2, height: 2),
                            group(id: 2, x: 45, y: 30, width: 2, height: 2),
                            group(id: 3, x: 70, y: 30, width: 2, height: 2)])

        let probe = group(id: 99, x: 32, y: 30, width: 2, height: 2)
        var previous = 0
        for distance in [1.0, 10.0, 25.0, 60.0] {
            let count = await outliers.groups(nearby: probe, within: distance).count
            XCTAssertGreaterThanOrEqual(count, previous,
                                        "a wider search found fewer at \(distance)")
            previous = count
        }
        XCTAssertGreaterThan(previous, 1)
    }

    // MARK: - clear

    func testClearingEmptiesBothCollections() async {
        let outliers = groups()
        await outliers.add([group(id: 1, x: 10, y: 10)])
        await outliers.dumpInTrash([group(id: 2, x: 50, y: 50)])
        await outliers.calculateOutlierImageData()

        await outliers.clear()

        let members = await outliers.getMembers()
        let trash = await outliers.getTrash()
        XCTAssertTrue(members.isEmpty)
        XCTAssertTrue(trash.isEmpty)
    }

    // MARK: - the paint data filename

    /// The filename is part of the on-disk layout a resume reads back, so it is worth pinning.
    func testThePaintDataFilenameIsStable() {
        XCTAssertEqual(OutlierGroups.outlierGroupPaintJsonFilename, "OutlierGroupPaintData.json")
    }

    func testLoadingPaintDataFromAMissingFileDoesNotThrow() async throws {
        let missing = NSTemporaryDirectory() + "/definitely-not-here-\(UUID().uuidString).json"
        let loaded = try await OutlierGroups.loadOutlierGroupPaintData(from: missing)
        XCTAssertNil(loaded)
    }
}
