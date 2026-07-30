import XCTest
@testable import StarCore

/// `Pixel` packs four 16-bit components into one `UInt64` and exposes them through computed
/// properties that mask and shift.  Every output frame star writes is assembled out of these,
/// so a shift that is off by 16 bits turns an image green, and a mask that is too wide makes
/// setting one channel clobber another.  Nothing here was covered.
final class PixelTests: XCTestCase {

    // MARK: - bit packing

    func testAFreshPixelIsAllZeroes() {
        let pixel = Pixel(numberOfComponents: 3)
        XCTAssertEqual(pixel.value, 0)
        XCTAssertEqual(pixel.red, 0)
        XCTAssertEqual(pixel.green, 0)
        XCTAssertEqual(pixel.blue, 0)
        XCTAssertEqual(pixel.alpha, 0)
        XCTAssertEqual(pixel.numberOfComponents, 3)
    }

    func testEachComponentReadsBackWhatWasWritten() {
        var pixel = Pixel(numberOfComponents: 4)
        pixel.red = 0x1111
        pixel.green = 0x2222
        pixel.blue = 0x3333
        pixel.alpha = 0x4444

        XCTAssertEqual(pixel.red, 0x1111)
        XCTAssertEqual(pixel.green, 0x2222)
        XCTAssertEqual(pixel.blue, 0x3333)
        XCTAssertEqual(pixel.alpha, 0x4444)
    }

    /// The component order in the packed word is red, green, blue, alpha from the low bits up.
    /// Anything serialising or memcpy-ing a `Pixel` depends on that layout.
    func testComponentsOccupyTheExpectedBitsOfTheWord() {
        var pixel = Pixel(numberOfComponents: 4)
        pixel.red = 0xAAAA
        XCTAssertEqual(pixel.value, 0x0000_0000_0000_AAAA)

        pixel = Pixel(numberOfComponents: 4)
        pixel.green = 0xAAAA
        XCTAssertEqual(pixel.value, 0x0000_0000_AAAA_0000)

        pixel = Pixel(numberOfComponents: 4)
        pixel.blue = 0xAAAA
        XCTAssertEqual(pixel.value, 0x0000_AAAA_0000_0000)

        pixel = Pixel(numberOfComponents: 4)
        pixel.alpha = 0xAAAA
        XCTAssertEqual(pixel.value, 0xAAAA_0000_0000_0000)
    }

    /// The masks in the setters are the part that is easy to get wrong: writing one channel
    /// has to leave the other three exactly as they were.
    func testWritingOneComponentLeavesTheOthersAlone() {
        var pixel = Pixel(numberOfComponents: 4)
        pixel.red = 0xFFFF
        pixel.green = 0xFFFF
        pixel.blue = 0xFFFF
        pixel.alpha = 0xFFFF

        pixel.green = 0
        XCTAssertEqual(pixel.red, 0xFFFF)
        XCTAssertEqual(pixel.green, 0)
        XCTAssertEqual(pixel.blue, 0xFFFF)
        XCTAssertEqual(pixel.alpha, 0xFFFF)

        pixel.alpha = 0x1234
        XCTAssertEqual(pixel.red, 0xFFFF)
        XCTAssertEqual(pixel.green, 0)
        XCTAssertEqual(pixel.blue, 0xFFFF)
        XCTAssertEqual(pixel.alpha, 0x1234)
    }

    func testEveryComponentCanBeOverwrittenRepeatedly() {
        var pixel = Pixel(numberOfComponents: 4)
        for value in [UInt16(0), 1, 0x8000, 0xFFFF, 0x0100, 0] {
            pixel.red = value
            pixel.green = value
            pixel.blue = value
            pixel.alpha = value
            XCTAssertEqual(pixel.red, value)
            XCTAssertEqual(pixel.green, value)
            XCTAssertEqual(pixel.blue, value)
            XCTAssertEqual(pixel.alpha, value)
        }
    }

    func testIntensityIsTheSumOfTheThreeColourChannels() {
        var pixel = Pixel(numberOfComponents: 4)
        pixel.red = 100
        pixel.green = 200
        pixel.blue = 300
        pixel.alpha = 0xFFFF
        XCTAssertEqual(pixel.intensity, 600, "alpha must not count toward intensity")
    }

    func testIntensityCannotOverflow() {
        var pixel = Pixel(numberOfComponents: 3)
        pixel.red = 0xFFFF
        pixel.green = 0xFFFF
        pixel.blue = 0xFFFF
        XCTAssertEqual(pixel.intensity, 3 * 0xFFFF)
    }

    // MARK: - merging a list

    func testMergingIdenticalThreeComponentPixelsGivesThatPixelBack() {
        var one = Pixel(numberOfComponents: 3)
        one.red = 100; one.green = 150; one.blue = 200

        let merged = Pixel(merging: [one, one, one])
        XCTAssertEqual(merged.red, 100)
        XCTAssertEqual(merged.green, 150)
        XCTAssertEqual(merged.blue, 200)
        XCTAssertEqual(merged.numberOfComponents, 3)
        XCTAssertEqual(merged.alpha, 0xFFFF, "a 3 component merge is fully opaque")
    }

    func testMergingAveragesTheChannels() {
        var dark = Pixel(numberOfComponents: 3)
        dark.red = 0; dark.green = 0; dark.blue = 0
        var light = Pixel(numberOfComponents: 3)
        light.red = 200; light.green = 100; light.blue = 50

        let merged = Pixel(merging: [dark, light])
        XCTAssertEqual(merged.red, 100)
        XCTAssertEqual(merged.green, 50)
        XCTAssertEqual(merged.blue, 25)
    }

    func testMergingASinglePixelIsIdentity() {
        var one = Pixel(numberOfComponents: 3)
        one.red = 1234; one.green = 5678; one.blue = 9012

        let merged = Pixel(merging: [one])
        XCTAssertEqual(merged.red, 1234)
        XCTAssertEqual(merged.green, 5678)
        XCTAssertEqual(merged.blue, 9012)
    }

    /// With four components each pixel's contribution is scaled by its own alpha, so a fully
    /// transparent pixel contributes no colour.
    func testAFullyTransparentPixelContributesNoColour() {
        var opaque = Pixel(numberOfComponents: 4)
        opaque.red = 200; opaque.green = 200; opaque.blue = 200; opaque.alpha = 0xFFFF
        var transparent = Pixel(numberOfComponents: 4)
        transparent.red = 0xFFFF; transparent.green = 0xFFFF; transparent.blue = 0xFFFF
        transparent.alpha = 0

        let merged = Pixel(merging: [opaque, transparent])
        XCTAssertEqual(merged.red, 100, "the transparent pixel's colour must not show through")
        XCTAssertEqual(merged.green, 100)
        XCTAssertEqual(merged.blue, 100)
        XCTAssertEqual(merged.numberOfComponents, 4)
        XCTAssertEqual(merged.alpha, 0x7FFF, "the alphas average too")
    }

    /// The result takes the widest component count of its inputs, which is how a mixed batch
    /// still produces a pixel the writer can use.
    func testTheMergedComponentCountIsTheWidestOfTheInputs() {
        var three = Pixel(numberOfComponents: 3)
        three.red = 100; three.green = 100; three.blue = 100
        var four = Pixel(numberOfComponents: 4)
        four.red = 100; four.green = 100; four.blue = 100; four.alpha = 0xFFFF

        XCTAssertEqual(Pixel(merging: [three, four]).numberOfComponents, 4)
        XCTAssertEqual(Pixel(merging: [four, three]).numberOfComponents, 4)
        XCTAssertEqual(Pixel(merging: [three, three]).numberOfComponents, 3)
    }

    // MARK: - alpha blending two pixels

    func testBlendingAtAlphaZeroIsAllTheSecondPixel() {
        var first = Pixel(numberOfComponents: 3)
        first.red = 0xFFFF; first.green = 0xFFFF; first.blue = 0xFFFF
        var second = Pixel(numberOfComponents: 3)
        second.red = 100; second.green = 200; second.blue = 300

        let blended = Pixel(merging: first, with: second, atAlpha: 0)
        XCTAssertEqual(blended.red, 100)
        XCTAssertEqual(blended.green, 200)
        XCTAssertEqual(blended.blue, 300)
    }

    func testBlendingAtAlphaOneIsAllTheFirstPixel() {
        var first = Pixel(numberOfComponents: 3)
        first.red = 100; first.green = 200; first.blue = 300
        var second = Pixel(numberOfComponents: 3)
        second.red = 0xFFFF; second.green = 0xFFFF; second.blue = 0xFFFF

        let blended = Pixel(merging: first, with: second, atAlpha: 1)
        XCTAssertEqual(blended.red, 100)
        XCTAssertEqual(blended.green, 200)
        XCTAssertEqual(blended.blue, 300)
    }

    func testBlendingHalfwayIsTheMidpoint() {
        var first = Pixel(numberOfComponents: 3)
        first.red = 0; first.green = 0; first.blue = 0
        var second = Pixel(numberOfComponents: 3)
        second.red = 200; second.green = 400; second.blue = 600

        let blended = Pixel(merging: first, with: second, atAlpha: 0.5)
        XCTAssertEqual(blended.red, 100)
        XCTAssertEqual(blended.green, 200)
        XCTAssertEqual(blended.blue, 300)
    }

    func testBlendingIsMonotonicInAlpha() {
        var first = Pixel(numberOfComponents: 3)
        first.red = 0xFF00
        var second = Pixel(numberOfComponents: 3)
        second.red = 0

        var previous: UInt16 = 0
        for alpha in stride(from: 0.0, through: 1.0, by: 0.1) {
            let red = Pixel(merging: first, with: second, atAlpha: alpha).red
            XCTAssertGreaterThanOrEqual(red, previous, "red went backwards at alpha \(alpha)")
            previous = red
        }
        XCTAssertEqual(previous, 0xFF00)
    }

    /// A blend always reports three components, even when both inputs had four.  Worth
    /// pinning: it means alpha is dropped rather than blended by this initializer.
    func testABlendAlwaysReportsThreeComponents() {
        var first = Pixel(numberOfComponents: 4)
        first.alpha = 0xFFFF
        var second = Pixel(numberOfComponents: 4)
        second.alpha = 0xFFFF
        XCTAssertEqual(Pixel(merging: first, with: second, atAlpha: 0.5).numberOfComponents, 3)
    }

    // MARK: - difference

    func testTwoIdenticalPixelsHaveNoDifference() {
        var pixel = Pixel(numberOfComponents: 3)
        pixel.red = 1000; pixel.green = 2000; pixel.blue = 3000
        XCTAssertEqual(pixel.difference(from: pixel), 0)
    }

    /// `difference` is written as
    ///     max(red + green + blue / 3, max(red, max(green, blue)))
    /// where `red`, `green` and `blue` are the signed per-channel deltas.  Swift's precedence
    /// divides only `blue` by three, so the first term is `red + green + blue/3` rather than
    /// the average of the three that the shape of the expression suggests.
    ///
    /// This test pins what the code computes today, so that the arithmetic is at least
    /// visible: with deltas of 300/300/300 the average would be 300, but the first term comes
    /// out at 700 and wins.
    func testDifferenceDividesOnlyBlueByThree() {
        var high = Pixel(numberOfComponents: 3)
        high.red = 300; high.green = 300; high.blue = 300
        let low = Pixel(numberOfComponents: 3)

        XCTAssertEqual(high.difference(from: low), 700,
                       "if this is now 300, the precedence was fixed — update this test")
    }

    /// The per-channel maximum is the other half of the expression, and it is what makes a
    /// single strongly differing channel register.
    func testASingleDifferingChannelStillRegisters() {
        var blueOnly = Pixel(numberOfComponents: 3)
        blueOnly.blue = 900
        let black = Pixel(numberOfComponents: 3)
        XCTAssertEqual(blueOnly.difference(from: black), 900)
    }

    /// The deltas are signed, so the difference is not symmetric — reversing the operands
    /// gives a negative answer.  Callers comparing against a positive threshold need to know
    /// which way round to ask.
    func testDifferenceIsSignedAndNotSymmetric() {
        var bright = Pixel(numberOfComponents: 3)
        bright.red = 600; bright.green = 600; bright.blue = 600
        let dark = Pixel(numberOfComponents: 3)

        XCTAssertGreaterThan(bright.difference(from: dark), 0)
        XCTAssertLessThan(dark.difference(from: bright), 0)
    }

    // MARK: - description

    func testDescriptionNamesTheThreeColourChannels() {
        var pixel = Pixel(numberOfComponents: 3)
        pixel.red = 1; pixel.green = 2; pixel.blue = 3
        let description = pixel.description
        XCTAssertTrue(description.contains("1"))
        XCTAssertTrue(description.contains("2"))
        XCTAssertTrue(description.contains("3"))
    }

    // MARK: - BasicColor, which is defined in terms of Pixel

    /// The test-paint colours are how outlier groups are visualised, so each one has to be a
    /// distinct pixel — two colours painting the same value would be indistinguishable in the
    /// debug output.
    func testEveryBasicColourPaintsADistinctPixelExceptTheTwoBlacks() {
        let colors: [BasicColor] = [.black, .red, .green, .yellow, .blue, .magenta, .cyan,
                                    .white, .reset, .brightBlack, .brightRed, .brightGreen,
                                    .brightYellow, .brightBlue, .brightMagenta, .brightCyan,
                                    .brightWhite]
        var seen: [UInt64: [BasicColor]] = [:]
        for color in colors { seen[color.pixel.value, default: []].append(color) }

        // black and reset are both 0 by design; nothing else may collide
        for (value, sharing) in seen where sharing.count > 1 {
            XCTAssertEqual(Set(sharing.map(\.name)), Set(["Black", "Reset"]),
                           "pixel value \(value) is painted by \(sharing.map(\.name))")
        }
        XCTAssertEqual(seen.count, colors.count - 1)
    }

    func testABasicColourPaintsThreeComponents() {
        XCTAssertEqual(BasicColor.red.pixel.numberOfComponents, 3)
    }

    func testTheBrightColoursAreBrighterThanTheirPlainCounterparts() {
        XCTAssertGreaterThan(BasicColor.brightRed.pixel.red, BasicColor.red.pixel.red)
        XCTAssertGreaterThan(BasicColor.brightGreen.pixel.green, BasicColor.green.pixel.green)
        XCTAssertGreaterThan(BasicColor.brightBlue.pixel.blue, BasicColor.blue.pixel.blue)
    }

    func testTheCompoundColoursAreTheSumOfTheirParts() {
        XCTAssertEqual(BasicColor.yellow.pixel.red, BasicColor.red.pixel.red)
        XCTAssertEqual(BasicColor.yellow.pixel.green, BasicColor.green.pixel.green)
        XCTAssertEqual(BasicColor.yellow.pixel.blue, 0)

        XCTAssertEqual(BasicColor.cyan.pixel.green, BasicColor.green.pixel.green)
        XCTAssertEqual(BasicColor.cyan.pixel.blue, BasicColor.blue.pixel.blue)
        XCTAssertEqual(BasicColor.cyan.pixel.red, 0)

        XCTAssertEqual(BasicColor.magenta.pixel.red, BasicColor.red.pixel.red)
        XCTAssertEqual(BasicColor.magenta.pixel.blue, BasicColor.blue.pixel.blue)
        XCTAssertEqual(BasicColor.magenta.pixel.green, 0)
    }

    /// The raw values double as ANSI escape sequences, so the string operators have to leave
    /// them intact around the text they wrap.
    func testTheStringOperatorsWrapTextInTheEscapeSequence() {
        XCTAssertEqual(BasicColor.red + "hi", BasicColor.red.rawValue + "hi")
        XCTAssertEqual("hi" + BasicColor.reset, "hi" + BasicColor.reset.rawValue)
    }

    func testEveryColourHasAName() {
        let colors: [BasicColor] = [.black, .red, .green, .yellow, .blue, .magenta, .cyan,
                                    .white, .reset, .brightBlack, .brightRed, .brightGreen,
                                    .brightYellow, .brightBlue, .brightMagenta, .brightCyan,
                                    .brightWhite]
        XCTAssertEqual(Set(colors.map(\.name)).count, colors.count,
                       "two colours share a name")
        for color in colors { XCTAssertFalse(color.name().isEmpty) }
    }
}

private extension BasicColor {
    var name: String { self.name() }
}
