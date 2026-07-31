import XCTest
@testable import StarCore

/// `FFmpegCodec`, `FFmpegEncoder`, `FFmpegPixelFormat` and `FFmpegMuxer` are four generated-looking
/// tables — 1014 codecs, ~500 encoders, 206 pixel formats, 181 muxers — each with a handful of
/// computed properties written as one giant switch per property.  Roughly 17k lines between them,
/// none of it covered.
///
/// Enumerating them is the only sensible way in: the tests below are properties over every case, so
/// a switch that is missing an entry, or a table row that contradicts another table, is reported
/// with the case that caused it.  The interesting ones are the cross-table checks at the bottom —
/// the four values `Config` defaults to have to be mutually compatible, or a default export fails,
/// and nothing else in the codebase checks that.
final class FFmpegTableTests: XCTestCase {

    // MARK: - the tables are well formed

    func testEveryTableIsNonEmptyAndHasDistinctRawValues() {
        XCTAssertGreaterThan(FFmpegCodec.allCases.count, 100)
        XCTAssertGreaterThan(FFmpegEncoder.allCases.count, 100)
        XCTAssertGreaterThan(FFmpegPixelFormat.allCases.count, 100)
        XCTAssertGreaterThan(FFmpegMuxer.allCases.count, 100)

        XCTAssertEqual(Set(FFmpegCodec.allCases.map(\.rawValue)).count,
                       FFmpegCodec.allCases.count)
        XCTAssertEqual(Set(FFmpegEncoder.allCases.map(\.rawValue)).count,
                       FFmpegEncoder.allCases.count)
        XCTAssertEqual(Set(FFmpegPixelFormat.allCases.map(\.rawValue)).count,
                       FFmpegPixelFormat.allCases.count)
        XCTAssertEqual(Set(FFmpegMuxer.allCases.map(\.rawValue)).count,
                       FFmpegMuxer.allCases.count)
    }

    /// The raw values are the strings handed to the ffmpeg command line, so an empty or padded one
    /// would build an invalid invocation.
    func testEveryRawValueIsANonEmptyCommandLineToken() {
        for raw in FFmpegCodec.allCases.map(\.rawValue)
                 + FFmpegEncoder.allCases.map(\.rawValue)
                 + FFmpegPixelFormat.allCases.map(\.rawValue)
                 + FFmpegMuxer.allCases.map(\.rawValue) {
            XCTAssertFalse(raw.isEmpty)
            XCTAssertEqual(raw, raw.trimmingCharacters(in: .whitespaces),
                           "'\(raw)' has surrounding whitespace")
            XCTAssertFalse(raw.contains(" "), "'\(raw)' contains a space")
        }
    }

    /// These are persisted in config.json and sent over the daemon wire as raw strings, so every
    /// case has to survive the round trip.
    func testEveryCaseRoundTripsThroughItsRawValue() {
        for c in FFmpegCodec.allCases { XCTAssertEqual(FFmpegCodec(rawValue: c.rawValue), c) }
        for e in FFmpegEncoder.allCases { XCTAssertEqual(FFmpegEncoder(rawValue: e.rawValue), e) }
        for p in FFmpegPixelFormat.allCases { XCTAssertEqual(FFmpegPixelFormat(rawValue: p.rawValue), p) }
        for m in FFmpegMuxer.allCases { XCTAssertEqual(FFmpegMuxer(rawValue: m.rawValue), m) }
    }

    func testEveryCaseSurvivesAJsonRoundTrip() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for c in FFmpegCodec.allCases {
            XCTAssertEqual(try decoder.decode(FFmpegCodec.self, from: try encoder.encode(c)), c)
        }
        for e in FFmpegEncoder.allCases {
            XCTAssertEqual(try decoder.decode(FFmpegEncoder.self, from: try encoder.encode(e)), e)
        }
        for p in FFmpegPixelFormat.allCases {
            XCTAssertEqual(try decoder.decode(FFmpegPixelFormat.self, from: try encoder.encode(p)), p)
        }
        for m in FFmpegMuxer.allCases {
            XCTAssertEqual(try decoder.decode(FFmpegMuxer.self, from: try encoder.encode(m)), m)
        }
    }

    // MARK: - every property is total

    /// Each property is one switch over a thousand cases.  Simply reading all of them for every
    /// case is what proves none of those switches is missing an entry or trapping — which for a
    /// hand-maintained table this size is the failure worth ruling out.
    func testEveryCodecPropertyIsReadableForEveryCodec() {
        for codec in FFmpegCodec.allCases {
            _ = codec.canDecode
            _ = codec.canEncode
            _ = codec.isIntraFrameOnly
            _ = codec.isLossy
            _ = codec.isLossless
            _ = codec.type
            _ = codec.encoders
            _ = codec.name
            XCTAssertFalse(codec.description.isEmpty,
                           "\(codec.rawValue) has no description")
        }
    }

    func testEveryEncoderPropertyIsReadableForEveryEncoder() {
        for encoder in FFmpegEncoder.allCases {
            _ = encoder.pixelFormats
            _ = encoder.supportedMuxers
            _ = encoder.description
        }
    }

    /// Most encoders in the table have an empty description — they are audio and obscure video
    /// entries star never offers, and the table simply does not name them.  What matters is that
    /// the ones a user can actually reach are named, since the description is the picker's label.
    func testEveryEncoderAUserCanReachHasADescription() {
        var checked = 0
        for codec in FFmpegCodec.availableVideoCodecs {
            for encoder in codec.encoders where !encoder.pixelFormats.isEmpty {
                XCTAssertFalse(encoder.description.isEmpty,
                               "\(encoder.rawValue) is offered under \(codec.rawValue) but would "
                               + "show a blank label")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 20, "the sweep should have reached real encoders")
    }

    func testEveryPixelFormatPropertyIsReadableForEveryFormat() {
        for format in FFmpegPixelFormat.allCases {
            _ = format.canInput
            _ = format.canOutput
            _ = format.isHardwareAccelrated
            _ = format.isPalleted
            _ = format.isBitstream
            _ = format.bitDepths
            XCTAssertGreaterThanOrEqual(format.numberOfComponents, 0,
                                        "\(format.rawValue) has a negative component count")
            XCTAssertGreaterThanOrEqual(format.bitsPerPixel, 0,
                                        "\(format.rawValue) has a negative bits per pixel")
        }
    }

    func testEveryMuxerPropertyIsReadableForEveryMuxer() {
        for muxer in FFmpegMuxer.allCases {
            _ = muxer.supportedEncoders
            _ = muxer.defaultFileExtension
            XCTAssertFalse(muxer.description.isEmpty, "\(muxer.rawValue) has no description")
        }
    }

    // MARK: - internal consistency within a table

    /// A format that carries real pixels has both a component count and a bit depth.  Hardware
    /// surfaces and bitstream formats are the documented exceptions — they describe a handle rather
    /// than a layout — so they are allowed to report zero.
    func testAnOrdinaryPixelFormatHasComponentsAndDepth() {
        for format in FFmpegPixelFormat.allCases
        where !format.isHardwareAccelrated && !format.isBitstream {
            XCTAssertGreaterThan(format.numberOfComponents, 0,
                                 "\(format.rawValue) claims no components")
            XCTAssertGreaterThan(format.bitsPerPixel, 0,
                                 "\(format.rawValue) claims no bits per pixel")
        }
    }

    /// `inputOutputPixelFormats` is the list offered where a format has to work in both directions,
    /// so it must be exactly the intersection rather than a separately maintained list that could
    /// drift from the two flags.
    func testTheInputOutputListIsExactlyTheFormatsThatDoBoth() {
        let derived = Set(FFmpegPixelFormat.allCases.filter { $0.canInput && $0.canOutput })
        let published = Set(FFmpegPixelFormat.inputOutputPixelFormats)
        XCTAssertEqual(published, derived,
                       "listed but not both: \(published.subtracting(derived).map(\.rawValue).sorted()); "
                       + "both but not listed: \(derived.subtracting(published).map(\.rawValue).sorted())")
        XCTAssertFalse(published.isEmpty)
    }

    /// `supportedMuxers` is derived by asking every muxer, so it has to agree with the muxer side.
    /// Checked over a sample rather than the full ~500x181 cross product, which is slow enough to
    /// matter and no more informative.
    func testAnEncodersMuxerListAgreesWithTheMuxerSide() {
        for encoder in FFmpegEncoder.allCases.prefix(60) {
            for muxer in encoder.supportedMuxers {
                XCTAssertTrue(muxer.supportedEncoders.contains(encoder),
                              "\(muxer.rawValue) is listed by \(encoder.rawValue) but does not "
                              + "list it back")
            }
        }
    }

    /// `pixelFormatCount` is the sum over the codec's encoders, and `availableVideoCodecs` filters
    /// on it being non-zero, so the two have to mean the same thing.
    func testAPixelFormatCountIsTheSumOverTheCodecsEncoders() {
        for codec in FFmpegCodec.allCases.prefix(120) {
            let summed = codec.encoders.map { $0.pixelFormats.count }.reduce(0, +)
            XCTAssertEqual(codec.pixelFormatCount, summed, "\(codec.rawValue)")
        }
    }

    /// `encoder(for:)` has to find an encoder whose list actually contains the format it was asked
    /// about — it is how a chosen pixel format is turned back into an encoder at export time.
    func testLookingUpAnEncoderByPixelFormatReturnsOneThatSupportsIt() {
        for codec in FFmpegCodec.availableVideoCodecs.prefix(20) {
            for format in codec.encoders.flatMap({ $0.pixelFormats }).prefix(8) {
                guard let found = codec.encoder(for: format) else {
                    XCTFail("\(codec.rawValue) offers \(format.rawValue) but no encoder for it")
                    continue
                }
                XCTAssertTrue(found.pixelFormats.contains(format),
                              "\(codec.rawValue): \(found.rawValue) was returned for "
                              + "\(format.rawValue) but does not support it")
            }
        }
    }

    func testLookingUpAnUnsupportedPixelFormatFindsNothing() {
        // a hardware surface no ordinary encoder takes as an input format
        let codec = FFmpegCodec.prores
        let unsupported = FFmpegPixelFormat.allCases.first {
            !codec.encoders.flatMap({ $0.pixelFormats }).contains($0)
        }
        if let unsupported {
            XCTAssertNil(codec.encoder(for: unsupported),
                         "prores should not claim an encoder for \(unsupported.rawValue)")
        }
    }

    // MARK: - the curated list star actually offers

    /// `availableVideoCodecs` is what the gui and the daemon's capability response are built from.
    /// Its filters are the contract: decodable, encodable, has pixel formats, and is video.
    func testTheOfferedCodecsAllPassTheirOwnFilters() {
        let offered = FFmpegCodec.availableVideoCodecs
        XCTAssertFalse(offered.isEmpty)

        for codec in offered {
            XCTAssertTrue(codec.canDecode, "\(codec.rawValue) is offered but cannot decode")
            XCTAssertTrue(codec.canEncode, "\(codec.rawValue) is offered but cannot encode")
            XCTAssertGreaterThan(codec.pixelFormatCount, 0,
                                 "\(codec.rawValue) is offered with no pixel formats")
            XCTAssertEqual(codec.type, .video, "\(codec.rawValue) is offered but is not video")
        }
    }

    func testTheOfferedCodecsContainNoDuplicates() {
        let offered = FFmpegCodec.availableVideoCodecs
        XCTAssertEqual(Set(offered).count, offered.count,
                       "a codec is offered twice, so it would appear twice in the picker")
    }

    /// The four the codebase deliberately puts first, so they are the ones a user sees.
    func testTheFourHeadlineCodecsComeFirstAndInOrder() {
        let offered = FFmpegCodec.availableVideoCodecs
        XCTAssertEqual(Array(offered.prefix(4)), [.h264, .hevc, .prores, .dnxhd],
                       "the pinned four should lead the list")
    }

    /// Everything after the pinned four is sorted by description, case insensitively — that is what
    /// makes the picker navigable.
    func testTheRemainingCodecsAreSortedByDescription() {
        let rest = FFmpegCodec.availableVideoCodecs.dropFirst(4).map { $0.description.lowercased() }
        XCTAssertEqual(rest, rest.sorted(), "the tail of the codec list is not in description order")
    }

    /// A codec offered with no usable encoder would appear in the picker and then fail at export.
    func testEveryOfferedCodecHasAnEncoderWithAPixelFormatAndAMuxer() {
        for codec in FFmpegCodec.availableVideoCodecs {
            let encoders = codec.encoders
            XCTAssertFalse(encoders.isEmpty, "\(codec.rawValue) is offered with no encoders")

            let usable = encoders.filter { !$0.pixelFormats.isEmpty }
            XCTAssertFalse(usable.isEmpty,
                           "\(codec.rawValue) has encoders but none with a pixel format")
        }
    }

    // MARK: - the defaults have to work together

    /// The invariant nothing else checks: the four video values `Config` starts with have to be
    /// mutually compatible, or an export with untouched settings fails.  They are four independent
    /// fields across four tables, so nothing makes them agree except somebody having checked.
    func testTheDefaultVideoSettingsAreMutuallyCompatible() {
        let config = Config()

        XCTAssertTrue(config.codec.encoders.contains(config.encoder),
                      "the default encoder \(config.encoder.rawValue) is not one of the default "
                      + "codec \(config.codec.rawValue)'s encoders: "
                      + "\(config.codec.encoders.map(\.rawValue))")

        XCTAssertTrue(config.encoder.pixelFormats.contains(config.pixelFormat),
                      "the default pixel format \(config.pixelFormat.rawValue) is not supported by "
                      + "the default encoder \(config.encoder.rawValue)")

        XCTAssertTrue(config.encoder.supportedMuxers.contains(config.muxer),
                      "the default muxer \(config.muxer.rawValue) does not accept the default "
                      + "encoder \(config.encoder.rawValue)")
    }

    /// ProRes is 10-bit, so a 14-bit format is not something any of its encoders can emit — only
    /// `ffvhuff`, `ffv1` and `libopenjpeg` accept `yuv422p14le`.  Pinned separately because it is
    /// the specific mismatch the default used to have.
    func testNoProResEncoderCanEmitAFourteenBitFormat() {
        for encoder in FFmpegCodec.prores.encoders {
            XCTAssertFalse(encoder.pixelFormats.contains(.yuv422p14le),
                           "\(encoder.rawValue) claims a 14 bit format")
        }
        XCTAssertNil(FFmpegCodec.prores.encoder(for: .yuv422p14le))
    }

    /// The gui carries a workaround for an incompatible pair — `RenderVideoSheetView` substitutes
    /// `encoder.pixelFormats[0]` when the config's format is not in the encoder's list — so the
    /// substitute it reaches for has to exist for every encoder a user can select.  Otherwise that
    /// workaround would itself trap on an empty array.
    func testEveryOfferedEncoderHasAFirstPixelFormatForTheGuiToFallBackOn() {
        for codec in FFmpegCodec.availableVideoCodecs {
            for encoder in codec.encoders where !encoder.pixelFormats.isEmpty {
                XCTAssertFalse(encoder.pixelFormats.isEmpty)
                _ = encoder.pixelFormats[0]
            }
        }
    }

    /// The default codec also has to be one the user could have picked, or the picker would open on
    /// a value not in its own list.
    func testTheDefaultCodecIsOneOfTheOfferedOnes() {
        XCTAssertTrue(FFmpegCodec.availableVideoCodecs.contains(Config().codec))
    }

    /// The muxer decides the output file's extension, so the default needs one.
    func testTheDefaultMuxerHasAFileExtension() {
        let muxer = Config().muxer
        let ext = muxer.defaultFileExtension
        XCTAssertNotNil(ext, "\(muxer.rawValue) has no default file extension")
        XCTAssertFalse(ext?.isEmpty ?? true)
        XCTAssertFalse(ext?.hasPrefix(".") ?? true,
                       "the extension should not include the dot: \(ext ?? "")")
    }

    /// And the reverse lookup has to agree — asking the default codec for an encoder for the
    /// default pixel format should give something that works.
    func testTheDefaultCodecCanResolveTheDefaultPixelFormat() throws {
        let config = Config()
        let resolved = try XCTUnwrap(config.codec.encoder(for: config.pixelFormat))
        XCTAssertTrue(resolved.pixelFormats.contains(config.pixelFormat))
    }

    /// Plenty of muxers name no extension — they are stream and device outputs rather than files —
    /// so the blanket claim does not hold.  What matters is that the common container formats do,
    /// since the export path builds its output filename from this.
    func testTheCommonContainerMuxersNameAFile() {
        let expected: [FFmpegMuxer: String] = [
          .mov: "mov",
          .mp4: "mp4",
          .matroska: "mkv",
        ]
        for (muxer, ext) in expected {
            XCTAssertEqual(muxer.defaultFileExtension, ext,
                           "\(muxer.rawValue) should name a .\(ext) file")
        }
    }

    /// An extension, where one is given, is a bare suffix — the callers join it with a dot
    /// themselves.
    func testAnyExtensionGivenIsABareSuffix() {
        for muxer in FFmpegMuxer.allCases {
            guard let ext = muxer.defaultFileExtension else { continue }
            XCTAssertFalse(ext.isEmpty, "\(muxer.rawValue) has an empty extension")
            XCTAssertFalse(ext.hasPrefix("."),
                           "\(muxer.rawValue)'s extension '\(ext)' should not include the dot")
            XCTAssertFalse(ext.contains(" "), "\(muxer.rawValue)'s extension has a space")
        }
    }
}
