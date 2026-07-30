import XCTest
@testable import StarCppBridge

/// `Line` is the polar form (theta in degrees, rho in pixels) that the Hough transform
/// speaks, and `polarCoords` is the conversion every caller goes through to get there from
/// a pair of pixels.  It hand-rolls the trigonometry with four special cases and a pair of
/// sign corrections, so these tests come at it from the invariant side: whatever theta and
/// rho it picks, `rho` must be the real perpendicular distance from the origin and the
/// points it was built from must still be on the line it describes.
final class LineTests: XCTestCase {

    /// The property that makes a (theta, rho) pair correct, independent of which of the
    /// several equivalent conventions the implementation happens to use: rho is the
    /// distance from the origin to the line, and both source points lie on it.
    private func assertPolarFormDescribes(_ p1: DoubleCoord,
                                          _ p2: DoubleCoord,
                                          file: StaticString = #filePath,
                                          line: UInt = #line)
    {
        let polar = Line(point1: p1, point2: p2)
        let direct = p1.standardLine(with: p2)

        XCTAssertEqual(polar.rho,
                       direct.distanceTo(DoubleCoord(x: 0, y: 0)),
                       accuracy: 1e-6,
                       "rho is not the perpendicular distance from the origin",
                       file: file, line: line)

        // and the line rebuilt from the polar form still contains the original points
        let rebuilt = polar.standardLine
        XCTAssertEqual(rebuilt.distanceTo(p1), 0, accuracy: 1e-6,
                       "point1 \(p1) fell off the rebuilt line", file: file, line: line)
        XCTAssertEqual(rebuilt.distanceTo(p2), 0, accuracy: 1e-6,
                       "point2 \(p2) fell off the rebuilt line", file: file, line: line)
    }

    // MARK: - the four special cases in polarCoords

    func testAVerticalLineToTheRightOfTheOriginIsThetaZero() {
        let (theta, rho) = polarCoords(point1: DoubleCoord(x: 12, y: 0),
                                       point2: DoubleCoord(x: 12, y: 99))
        XCTAssertEqual(theta, 0)
        XCTAssertEqual(rho, 12)
    }

    func testAVerticalLineToTheLeftOfTheOriginIsTheta180WithPositiveRho() {
        let (theta, rho) = polarCoords(point1: DoubleCoord(x: -12, y: 0),
                                       point2: DoubleCoord(x: -12, y: 99))
        XCTAssertEqual(theta, 180)
        XCTAssertEqual(rho, 12, "rho is a distance and stays positive")
    }

    func testAHorizontalLineBelowTheOriginIsTheta90() {
        let (theta, rho) = polarCoords(point1: DoubleCoord(x: 0, y: 30),
                                       point2: DoubleCoord(x: 99, y: 30))
        XCTAssertEqual(theta, 90)
        XCTAssertEqual(rho, 30)
    }

    func testAHorizontalLineAboveTheOriginIsTheta270WithPositiveRho() {
        let (theta, rho) = polarCoords(point1: DoubleCoord(x: 0, y: -30),
                                       point2: DoubleCoord(x: 99, y: -30))
        XCTAssertEqual(theta, 270)
        XCTAssertEqual(rho, 30)
    }

    /// A line straight through the origin has rho == 0, and the `rho > 0` test in the
    /// vertical branch then falls to the else, giving theta 180 rather than 0.  Harmless
    /// (rho 0 makes theta's sign moot) but worth recording so it does not read as a bug.
    func testAVerticalLineThroughTheOriginGivesRhoZero() {
        let (theta, rho) = polarCoords(point1: DoubleCoord(x: 0, y: -5),
                                       point2: DoubleCoord(x: 0, y: 5))
        XCTAssertEqual(rho, 0)
        XCTAssertEqual(theta, 180)
    }

    // MARK: - the general case

    func testTheClassicDiagonalGetsTheTextbookAnswer() {
        // x + y = 10 is 45 degrees away from the origin at a distance of 10/sqrt(2)
        let (theta, rho) = polarCoords(point1: DoubleCoord(x: 0, y: 10),
                                       point2: DoubleCoord(x: 10, y: 0))
        XCTAssertEqual(theta, 45, accuracy: 1e-9)
        XCTAssertEqual(rho, 10 / 2.0.squareRoot(), accuracy: 1e-9)
    }

    /// Image coordinates are all non-negative, so these are the lines star actually sees:
    /// lines that cross the picture.  Both slope signs and both iteration orientations.
    func testRhoAndThetaDescribeAnyLineCrossingThePicture() {
        assertPolarFormDescribes(DoubleCoord(x: 0, y: 10), DoubleCoord(x: 10, y: 0))
        assertPolarFormDescribes(DoubleCoord(x: 2, y: 3), DoubleCoord(x: 9, y: 17))
        assertPolarFormDescribes(DoubleCoord(x: 100, y: 1), DoubleCoord(x: 101, y: 900))
        assertPolarFormDescribes(DoubleCoord(x: 5, y: 300), DoubleCoord(x: 400, y: 20))
        assertPolarFormDescribes(DoubleCoord(x: 0, y: 10), DoubleCoord(x: 100, y: 50))
        assertPolarFormDescribes(DoubleCoord(x: 10, y: 0), DoubleCoord(x: 50, y: 100))
        assertPolarFormDescribes(DoubleCoord(x: 1920, y: 4), DoubleCoord(x: 3, y: 1080))
        assertPolarFormDescribes(DoubleCoord(x: 30, y: 12), DoubleCoord(x: 4000, y: 700))
    }

    /// Negative coordinates are not merely hypothetical here: `OutlierGroup.originZeroLine`
    /// offsets `twoPoints` by `bounds.min` and feeds the result back through `polarCoords`,
    /// and `twoPoints` can sit either side of the origin.  Lines with their closest approach
    /// in any of the four quadrants have to work.
    func testLinesInEveryQuadrantAreDescribedCorrectly() {
        assertPolarFormDescribes(DoubleCoord(x: -2, y: -3), DoubleCoord(x: -9, y: -17))
        assertPolarFormDescribes(DoubleCoord(x: 2, y: -3), DoubleCoord(x: 9, y: -17))
        assertPolarFormDescribes(DoubleCoord(x: -2, y: 3), DoubleCoord(x: -9, y: 17))
        assertPolarFormDescribes(DoubleCoord(x: -40, y: -12), DoubleCoord(x: -12, y: -40))
        assertPolarFormDescribes(DoubleCoord(x: -100, y: 50), DoubleCoord(x: 50, y: -100))
        assertPolarFormDescribes(DoubleCoord(x: -1, y: 640), DoubleCoord(x: 17, y: -40))
    }

    // MARK: - known limitations

    /// A line through [0, 0] gets rho == 0, which is the correct distance — but the polar
    /// form is then not enough to get the line back, because `twoPoints` scales both of its
    /// points by rho and so collapses them onto the origin.  `standardLine` sees two
    /// identical points, takes its vertical branch, and answers "x = 0" for a line of any
    /// slope.
    ///
    /// This is a limitation of the current implementation rather than a property worth
    /// having, and it is pinned because it is silent: a walk along such a line reports every
    /// pixel in column 0.  Real frames only reach it for a trail passing exactly through the
    /// top-left pixel, but any use of these types on centred coordinates would hit it often.
    func testALineThroughTheOriginLosesItsSlope() {
        let throughOrigin = Line(point1: DoubleCoord(x: 0, y: 0), point2: DoubleCoord(x: 100, y: 40))

        XCTAssertEqual(throughOrigin.rho, 0, "rho is the distance from the origin, so it is 0")
        // theta falls back to the perpendicular's own direction, which is still meaningful —
        // the line is at right angles to it — so it is finite and in range
        XCTAssertFalse(throughOrigin.theta.isNaN)
        XCTAssertGreaterThanOrEqual(throughOrigin.theta, 0)
        XCTAssertLessThan(throughOrigin.theta, 360)

        // but both of twoPoints collapse onto the origin
        let (p1, p2) = throughOrigin.twoPoints
        XCTAssertEqual(p1.x, 0); XCTAssertEqual(p1.y, 0)
        XCTAssertEqual(p2.x, 0); XCTAssertEqual(p2.y, 0)

        // so the rebuilt line is "x = 0" regardless of the slope it was built from
        let rebuilt = throughOrigin.standardLine
        XCTAssertEqual(rebuilt.a, 1)
        XCTAssertEqual(rebuilt.b, 0)
        XCTAssertEqual(rebuilt.c, 0)
        XCTAssertFalse(rebuilt.y(forX: 10).isFinite,
                       "the degenerate line cannot be solved for y")

        // a line of a completely different slope through the origin rebuilds identically
        let other = Line(point1: DoubleCoord(x: 0, y: 0), point2: DoubleCoord(x: 3, y: 90))
        XCTAssertTrue(other.standardLine == rebuilt)
    }

    /// theta is still assigned by the axis-aligned special cases before any of the general
    /// arithmetic runs, so those two report cleanly even at rho 0.  (Reconstruction is still
    /// lost, for the reason above — this is only about theta and rho.)
    func testAxisAlignedLinesThroughTheOriginStillReportACleanThetaAndRho() {
        let (vTheta, vRho) = polarCoords(point1: DoubleCoord(x: 0, y: -5),
                                         point2: DoubleCoord(x: 0, y: 5))
        XCTAssertEqual(vRho, 0)
        XCTAssertEqual(vTheta, 180)

        let (hTheta, hRho) = polarCoords(point1: DoubleCoord(x: -5, y: 0),
                                         point2: DoubleCoord(x: 5, y: 0))
        XCTAssertEqual(hRho, 0)
        XCTAssertEqual(hTheta, 270)
    }

    /// A line and its mirror image through the origin are the same distance away, so rho
    /// cannot tell them apart — only theta can, by pointing at one or the other.  This is a
    /// regression test: theta used to be guessed from the angle the line rises at and then
    /// sign-corrected only for lines sloping the same way in x and y.  The other branch was a
    /// bare `90 - line_theta`, so a line whose closest approach lay in the negative quadrant
    /// came back pointing 180 degrees the wrong way and the pair described its mirror image.
    func testALineAndItsMirrorThroughTheOriginAreToldApartByTheta() {
        // 2x + y + 1 = 0, closest approach at [-0.4, -0.2] — down and left of the origin
        let negativeSide = Line(point1: DoubleCoord(x: -2, y: 3), point2: DoubleCoord(x: -9, y: 17))
        // 2x + y - 1 = 0, closest approach at [0.4, 0.2] — the mirror image
        let positiveSide = Line(point1: DoubleCoord(x: 2, y: -3), point2: DoubleCoord(x: 9, y: -17))

        // same distance from the origin...
        XCTAssertEqual(negativeSide.rho, positiveSide.rho, accuracy: 1e-9)
        // ...opposite directions from it
        XCTAssertEqual(positiveSide.theta, 26.565051177078, accuracy: 1e-9)
        XCTAssertEqual(negativeSide.theta, 206.565051177078, accuracy: 1e-9)
        XCTAssertEqual(abs(negativeSide.theta - positiveSide.theta), 180, accuracy: 1e-9)

        // and each rebuilds to the line it actually came from
        assertPolarFormDescribes(DoubleCoord(x: -2, y: 3), DoubleCoord(x: -9, y: 17))
        assertPolarFormDescribes(DoubleCoord(x: 2, y: -3), DoubleCoord(x: 9, y: -17))
    }

    /// The invariant that makes theta and rho a matched pair: stepping rho pixels from the
    /// origin along theta lands *on* the line.  Getting the sign wrong put that point twice
    /// rho away instead, on the far side of the origin.
    func testSteppingRhoAlongThetaLandsOnTheLine() {
        let pairs: [(DoubleCoord, DoubleCoord)] = [
          (DoubleCoord(x: -2, y: 3),   DoubleCoord(x: -9, y: 17)),
          (DoubleCoord(x: 2, y: -3),   DoubleCoord(x: 9, y: -17)),
          (DoubleCoord(x: -40, y: -12), DoubleCoord(x: -12, y: -40)),
          (DoubleCoord(x: -1, y: 100), DoubleCoord(x: 17, y: -40)),
          (DoubleCoord(x: 3, y: 17),   DoubleCoord(x: 640, y: 0.5)),
        ]
        for (p1, p2) in pairs {
            let line = Line(point1: p1, point2: p2)
            let foot = DoubleCoord(x: line.rho * cos(line.theta*DEGREES_TO_RADIANS),
                                   y: line.rho * sin(line.theta*DEGREES_TO_RADIANS))
            XCTAssertEqual(p1.standardLine(with: p2).distanceTo(foot), 0, accuracy: 1e-6,
                           "rho along theta missed the line through \(p1) and \(p2)")
        }
    }

    /// A sweep over a grid spanning both signs, which is what caught the mirroring in the
    /// first place: 434 of these 3080 pairs used to fail, off by as much as 73 pixels.
    func testEveryPointPairOnASignedGridRoundTrips() {
        let coords: [Double] = [-40, -12, -1, 0.5, 3, 17, 100, 640]
        var checked = 0
        for x1 in coords {
            for y1 in coords {
                for x2 in coords where x2 != x1 {
                    for y2 in coords where y2 != y1 {
                        let p1 = DoubleCoord(x: x1, y: y1), p2 = DoubleCoord(x: x2, y: y2)
                        let line = Line(point1: p1, point2: p2)
                        // a line through the origin has no direction to recover — separately
                        // covered by testALineThroughTheOriginLosesItsSlope
                        guard line.rho > 0 else { continue }

                        let rebuilt = line.standardLine
                        XCTAssertEqual(rebuilt.distanceTo(p1), 0, accuracy: 1e-6,
                                       "\(p1) fell off the line rebuilt from \(p1)/\(p2)")
                        XCTAssertEqual(rebuilt.distanceTo(p2), 0, accuracy: 1e-6,
                                       "\(p2) fell off the line rebuilt from \(p1)/\(p2)")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 3000, "the sweep stopped covering what it used to")
    }

    /// theta stays in 0..<360, matching the axis-aligned cases which answer 0, 90, 180, 270.
    /// It used to be able to come back negative (the `line_theta - 90` branch could reach -90).
    func testThetaIsAlwaysInTheZeroToThreeSixtyRange() {
        let coords: [Double] = [-40, -1, 3, 100]
        for x1 in coords {
            for y1 in coords {
                for x2 in coords where x2 != x1 {
                    for y2 in coords where y2 != y1 {
                        let line = Line(point1: DoubleCoord(x: x1, y: y1),
                                        point2: DoubleCoord(x: x2, y: y2))
                        XCTAssertGreaterThanOrEqual(line.theta, 0,
                                                    "theta \(line.theta) for [\(x1),\(y1)]->[\(x2),\(y2)]")
                        XCTAssertLessThan(line.theta, 360,
                                          "theta \(line.theta) for [\(x1),\(y1)]->[\(x2),\(y2)]")
                    }
                }
            }
        }
    }

    /// rho is a distance, so it is never negative regardless of where the line sits.
    func testRhoIsNeverNegative() {
        let coords: [Double] = [-40, -1, 3, 100]
        for x1 in coords {
            for y1 in coords {
                for x2 in coords where x2 != x1 {
                    for y2 in coords where y2 != y1 {
                        let line = Line(point1: DoubleCoord(x: x1, y: y1),
                                        point2: DoubleCoord(x: x2, y: y2))
                        XCTAssertGreaterThanOrEqual(line.rho, 0)
                    }
                }
            }
        }
    }

    /// The two points are given in whichever order the caller found them; the line they
    /// describe cannot depend on that.  This is the invariant the `needFlip` /
    /// `isPositiveInBothDirections` corrections in `polarCoords` exist to preserve.
    func testSwappingThePointsDescribesTheSameLine() {
        let pairs: [(DoubleCoord, DoubleCoord)] = [
          (DoubleCoord(x: 0, y: 10), DoubleCoord(x: 10, y: 0)),
          (DoubleCoord(x: 2, y: 3),  DoubleCoord(x: 9, y: 17)),
          (DoubleCoord(x: -5, y: 8), DoubleCoord(x: 7, y: -2)),
          (DoubleCoord(x: 33, y: 4), DoubleCoord(x: 12, y: 90)),
        ]
        for (p1, p2) in pairs {
            let forward = Line(point1: p1, point2: p2)
            let backward = Line(point1: p2, point2: p1)
            XCTAssertEqual(forward.rho, backward.rho, accuracy: 1e-6,
                           "rho changed when \(p1)/\(p2) were swapped")
            XCTAssertTrue(forward.standardLine == backward.standardLine,
                          "the line through \(p1) and \(p2) changed when they were swapped")
        }
    }

    /// Sliding along a line must not change its polar description.
    func testAnyTwoPointsOnALineGiveTheSameLine()  {
        let reference = DoubleCoord(x: 0, y: 10).standardLine(with: DoubleCoord(x: 10, y: 0))
        let base = Line(point1: DoubleCoord(x: 0, y: 10), point2: DoubleCoord(x: 10, y: 0))

        for x in [2.0, 4.0, 6.0, 8.0] {
            let a = DoubleCoord(x: x, y: reference.y(forX: x))
            let b = DoubleCoord(x: x + 1, y: reference.y(forX: x + 1))
            let line = Line(point1: a, point2: b)
            XCTAssertEqual(line.theta, base.theta, accuracy: 1e-6)
            XCTAssertEqual(line.rho, base.rho, accuracy: 1e-6)
        }
    }

    // MARK: - twoPoints

    /// `twoPoints` builds one point at rho along theta and a second via a 45 degree
    /// triangle.  Both have to land on the line, which is what makes the polar -> standard
    /// conversion work at all.
    func testBothOfTwoPointsLieOnTheLine() {
        for theta in stride(from: 5.0, to: 360.0, by: 15.0) {
            let line = Line(theta: theta, rho: 25)
            let (p1, p2) = line.twoPoints

            // rho is by construction the distance from the origin to the first point
            XCTAssertEqual(DoubleCoord(x: 0, y: 0).distance(to: p1), 25, accuracy: 1e-9,
                           "theta \(theta): the rho point is not rho from the origin")

            // the second point projects onto the same perpendicular distance
            let projection = p2.x * cos(theta * DEGREES_TO_RADIANS)
                           + p2.y * sin(theta * DEGREES_TO_RADIANS)
            XCTAssertEqual(projection, 25, accuracy: 1e-9,
                           "theta \(theta): the hypotenuse point is not on the line")
        }
    }

    func testTwoPointsAreDistinctSoTheyDefineALine() {
        for theta in stride(from: 0.0, to: 360.0, by: 30.0) {
            let (p1, p2) = Line(theta: theta, rho: 40).twoPoints
            XCTAssertGreaterThan(p1.distance(to: p2), 1e-6,
                                 "theta \(theta) produced two coincident points")
        }
    }

    // MARK: - round trip

    func testAPolarLineSurvivesATripThroughStandardForm() {
        for theta in stride(from: 10.0, to: 350.0, by: 20.0) {
            let original = Line(theta: theta, rho: 30)
            let viaStandard = original.standardLine.polarLine

            XCTAssertEqual(viaStandard.rho, original.rho, accuracy: 1e-6,
                           "rho drifted at theta \(theta)")
            // theta is only pinned modulo 180: a line has two equally valid normals
            let delta = abs(viaStandard.theta - original.theta).truncatingRemainder(dividingBy: 180)
            XCTAssertTrue(delta < 1e-6 || abs(delta - 180) < 1e-6,
                          "theta \(original.theta) came back as \(viaStandard.theta)")
        }
    }

    // MARK: - votes, equality and hashing

    /// `hash(into:)` deliberately combines only theta and rho, but the synthesised `==`
    /// still compares `votes`.  Two lines in the same place with different vote counts are
    /// therefore unequal yet hash together — legal, but it means a Set keyed on Line does
    /// not deduplicate by position, which is easy to assume it does.
    func testVotesAffectEqualityButNotTheHash() {
        let a = Line(theta: 30, rho: 40, votes: 1)
        let b = Line(theta: 30, rho: 40, votes: 2)

        XCTAssertNotEqual(a, b)

        var hasherA = Hasher(), hasherB = Hasher()
        a.hash(into: &hasherA)
        b.hash(into: &hasherB)
        XCTAssertEqual(hasherA.finalize(), hasherB.finalize())

        XCTAssertEqual(Set([a, b]).count, 2, "votes keep them as separate Set members")
    }

    func testVotesDefaultToZeroAndAreCarriedThrough() {
        XCTAssertEqual(Line(theta: 1, rho: 2).votes, 0)
        XCTAssertEqual(Line(theta: 1, rho: 2, votes: 77).votes, 77)
        XCTAssertEqual(Line(point1: DoubleCoord(x: 0, y: 1),
                            point2: DoubleCoord(x: 1, y: 0), votes: 5).votes, 5)
    }

    func testIdenticalLinesAreEqualAndCollapseInASet() {
        let a = Line(theta: 12.5, rho: 33.25, votes: 4)
        let b = Line(theta: 12.5, rho: 33.25, votes: 4)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    func testLineSurvivesAJsonRoundTrip() throws {
        let original = Line(theta: 123.456, rho: 78.9, votes: 42)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Line.self, from: data), original)
    }
}
