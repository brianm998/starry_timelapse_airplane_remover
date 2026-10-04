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
    /// about — it is how a chosen pixel format is turned back into an encoder at export time.  It
    /// looks only among the encoders a user can pick, and the formats they can pick.
    func testLookingUpAnEncoderByPixelFormatReturnsOneThatSupportsIt() {
        for codec in FFmpegCodec.availableVideoCodecs.prefix(20) {
            for format in codec.availableEncoders.flatMap({ $0.usablePixelFormats }).prefix(8) {
                guard let found = codec.encoder(for: format) else {
                    XCTFail("\(codec.rawValue) offers \(format.rawValue) but no encoder for it")
                    continue
                }
                XCTAssertTrue(found.usablePixelFormats.contains(format),
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
    /// the first usable pixel format when the config's format is not in the encoder's list — so
    /// the substitute it reaches for has to exist for every encoder a user can select, and have
    /// a container to go in.  Otherwise that workaround would itself trap on an empty array.
    func testEveryOfferedEncoderHasAFirstPixelFormatAndAContainerForTheGuiToFallBackOn() {
        for codec in FFmpegCodec.availableVideoCodecs {
            XCTAssertFalse(codec.availableEncoders.isEmpty, codec.rawValue)
            for encoder in codec.availableEncoders {
                XCTAssertFalse(encoder.usablePixelFormats.isEmpty, "\(encoder.rawValue) has no usable pixel format")
                XCTAssertFalse(encoder.supportedMuxers.isEmpty, "\(encoder.rawValue) has no container")
            }
        }
    }

    // MARK: - hardware encoders

    /// The pixel formats an encoder's table entry lists include its GPU surfaces, and
    /// VideoToolbox's come first.  Those are never something a folder of TIFFs can be, so none
    /// may reach the dialog, least of all as the one it opens on.
    func testNoGPUSurfaceFormatIsEverOffered() {
        for codec in FFmpegCodec.availableVideoCodecs {
            for encoder in codec.availableEncoders {
                for format in encoder.usablePixelFormats {
                    XCTAssertFalse(format.isHardwareAccelrated, "\(encoder.rawValue) offers \(format.rawValue)")
                    XCTAssertTrue(format.canOutput, "\(encoder.rawValue) offers \(format.rawValue)")
                }
            }
        }
        XCTAssertTrue(FFmpegEncoder.h264_videotoolbox.pixelFormats.contains(.videotoolbox_vld),
                      "the table is expected to list the surface format, or this test proves nothing")
        XCTAssertFalse(FFmpegEncoder.h264_videotoolbox.usablePixelFormats.contains(.videotoolbox_vld))
    }

    /// The three GPU families star can drive without anything but `-c:v`: Apple's media engine,
    /// NVIDIA's NVENC and AMD's AMF, each for the codecs that matter in a timelapse delivery.
    func testTheGPUEncodersStarCanDriveAreInTheTables() {
        let expected: [FFmpegCodec: [FFmpegEncoder]] = [
          .h264: [.h264_videotoolbox, .h264_nvenc, .h264_amf],
          .hevc: [.hevc_videotoolbox, .hevc_nvenc, .hevc_amf],
          .av1: [.av1_nvenc, .av1_amf],
          .prores: [.prores_videotoolbox],
        ]
        for (codec, encoders) in expected {
            for encoder in encoders {
                XCTAssertTrue(codec.encoders.contains(encoder), "\(encoder.rawValue) is not an encoder of \(codec.rawValue)")
                XCTAssertTrue(encoder.isHardware, encoder.rawValue)
                XCTAssertFalse(encoder.usablePixelFormats.isEmpty, "\(encoder.rawValue) has no usable pixel format")
                XCTAssertFalse(encoder.supportedMuxers.isEmpty, "\(encoder.rawValue) has no container")
                XCTAssertFalse(encoder.description.isEmpty, "\(encoder.rawValue) has no description")
            }
        }
    }

    /// An encoder fits the containers its codec does, so a hardware H.264 encoder has to be
    /// usable in every container a software one is.
    func testAHardwareEncoderWritesTheSameContainersAsItsSoftwareSibling() {
        for (hardware, software) in [(FFmpegEncoder.h264_nvenc, FFmpegEncoder.libx264),
                                     (.hevc_nvenc, .libx265),
                                     (.h264_videotoolbox, .libx264)] {
            let hardwareMuxers = Set(hardware.supportedMuxers)
            let softwareMuxers = Set(software.supportedMuxers)
            XCTAssertEqual(hardwareMuxers, softwareMuxers,
                           "\(hardware.rawValue) vs \(software.rawValue): "
                           + "\(hardwareMuxers.symmetricDifference(softwareMuxers).map(\.rawValue).sorted())")
        }
    }

    func testOnlyTheGPUAPIsAreCalledHardware() {
        for encoder in [FFmpegEncoder.libx264, .libx265, .prores_ks, .libsvtav1, .libvpx_vp9, .dnxhd] {
            XCTAssertFalse(encoder.isHardware, encoder.rawValue)
        }
        for encoder in [FFmpegEncoder.h264_videotoolbox, .prores_videotoolbox, .h264_nvenc, .av1_nvenc, .hevc_amf] {
            XCTAssertTrue(encoder.isHardware, encoder.rawValue)
        }
    }

    /// Software encoders are listed before the hardware ones, so a codec's dialog opens on the
    /// encoder that behaves the same on every machine.
    func testSoftwareEncodersComeBeforeHardwareOnes() {
        for codec in FFmpegCodec.availableVideoCodecs {
            let flags = codec.availableEncoders.map(\.isHardware)
            XCTAssertEqual(flags, flags.sorted { !$0 && $1 }, "\(codec.rawValue): \(codec.availableEncoders.map(\.rawValue))")
        }
        XCTAssertEqual(FFmpegCodec.h264.availableEncoders.first, .libx264)
        XCTAssertEqual(FFmpegCodec.hevc.availableEncoders.first, .libx265)
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

    // MARK: - choosing a consistent set of settings

    func testAConsistentChoiceIsLeftAlone() {
        let kept = FFmpegCodec.consistentSettings(codec: .hevc, encoder: .libx265,
                                                  pixelFormat: .yuv420p10le, muxer: .mp4)
        XCTAssertEqual(kept?.codec, .hevc)
        XCTAssertEqual(kept?.encoder, .libx265)
        XCTAssertEqual(kept?.pixelFormat, .yuv420p10le)
        XCTAssertEqual(kept?.muxer, .mp4)
    }

    /// What the gui does with whatever a config says: an encoder from another codec, a pixel
    /// format the encoder cannot write, a container that cannot hold it, each replaced by one
    /// that fits and the rest kept.
    func testEachPartThatDoesNotFitIsReplacedAndTheRestKept() throws {
        let fixed = try XCTUnwrap(FFmpegCodec.consistentSettings(
                                    codec: .prores, encoder: .libx264,
                                    pixelFormat: .yuv420p, muxer: .mp4))
        XCTAssertEqual(fixed.codec, .prores)
        XCTAssertTrue(FFmpegCodec.prores.availableEncoders.contains(fixed.encoder))
        XCTAssertTrue(fixed.encoder.usablePixelFormats.contains(fixed.pixelFormat))
        XCTAssertTrue(fixed.encoder.supportedMuxers.contains(fixed.muxer))

        let pixelFormatFixed = try XCTUnwrap(FFmpegCodec.consistentSettings(
                                               codec: .prores, encoder: .prores_ks,
                                               pixelFormat: .yuv420p, muxer: .mov))
        XCTAssertEqual(pixelFormatFixed.encoder, .prores_ks, "an encoder that fits is kept")
        XCTAssertEqual(pixelFormatFixed.muxer, .mov, "a container that fits is kept")
        XCTAssertNotEqual(pixelFormatFixed.pixelFormat, .yuv420p, "prores_ks cannot write 8-bit 4:2:0")
        XCTAssertTrue(FFmpegEncoder.prores_ks.usablePixelFormats.contains(pixelFormatFixed.pixelFormat))
    }

    func testACodecThatIsNotOfferedFallsBackToOneThatIs() throws {
        let notOffered = try XCTUnwrap(FFmpegCodec.allCases.first {
            !FFmpegCodec.availableVideoCodecs.contains($0)
        })
        let fixed = try XCTUnwrap(FFmpegCodec.consistentSettings(
                                    codec: notOffered, encoder: .libx264,
                                    pixelFormat: .yuv420p, muxer: .mp4))
        XCTAssertTrue(FFmpegCodec.availableVideoCodecs.contains(fixed.codec))
        XCTAssertTrue(fixed.codec.availableEncoders.contains(fixed.encoder))
    }

    /// Whatever comes in, what goes out indexes safely: the gui reads the first entry of each list.
    func testTheResultIsAlwaysSomethingTheDialogCanShow() throws {
        for codec in FFmpegCodec.allCases.prefix(80) {
            let fixed = try XCTUnwrap(FFmpegCodec.consistentSettings(
                                        codec: codec, encoder: .prores_ks,
                                        pixelFormat: .gray, muxer: .null))
            XCTAssertTrue(FFmpegCodec.availableVideoCodecs.contains(fixed.codec), codec.rawValue)
            XCTAssertTrue(fixed.codec.availableEncoders.contains(fixed.encoder), codec.rawValue)
            XCTAssertTrue(fixed.encoder.usablePixelFormats.contains(fixed.pixelFormat), codec.rawValue)
            XCTAssertTrue(fixed.encoder.supportedMuxers.contains(fixed.muxer), codec.rawValue)
        }
    }

    /// A new codec's container should be the one it belongs in, not whichever comes first in
    /// a list of nearly two hundred.
    func testTheDefaultContainerIsTheNaturalOneNotTheFirstInTheList() {
        let expected: [(FFmpegCodec, FFmpegEncoder, FFmpegMuxer)] = [
          (.prores, .prores_ks, .mov), (.dnxhd, .dnxhd, .mov),
          (.h264, .libx264, .mp4), (.hevc, .libx265, .mp4), (.av1, .libsvtav1, .mp4),
        ]
        for (codec, encoder, container) in expected {
            XCTAssertEqual(codec.defaultMuxer(for: encoder), container, "\(codec.rawValue)/\(encoder.rawValue)")
        }
    }

    // MARK: - quality defaults for the GPU encoders

    /// Only an encoder whose own default is poor gets extra arguments, and they are well-formed
    /// option/value pairs, since they are spliced into an ffmpeg command line.
    func testOnlyHardwareEncodersGetQualityArgumentsAndTheyArePairs() {
        for encoder in FFmpegEncoder.allCases {
            let arguments = encoder.defaultQualityArguments
            if arguments.isEmpty { continue }
            XCTAssertTrue(encoder.isHardware, "\(encoder.rawValue) is software but has quality arguments")
            XCTAssertEqual(arguments.count % 2, 0, encoder.rawValue)
            for (index, argument) in arguments.enumerated() {
                XCTAssertEqual(argument.hasPrefix("-") && argument.count > 1, index % 2 == 0,
                               "\(encoder.rawValue): '\(argument)' is in the wrong place")
            }
        }
    }

    func testNVENCRunsAtConstantQualityNotItsTwoMegabitDefault() {
        for encoder in [FFmpegEncoder.h264_nvenc, .hevc_nvenc, .av1_nvenc] {
            let arguments = encoder.defaultQualityArguments
            XCTAssertEqual(arguments.firstIndex(of: "-rc").map { arguments[$0 + 1] }, "vbr", encoder.rawValue)
            XCTAssertNotNil(arguments.firstIndex(of: "-cq"), encoder.rawValue)
            XCTAssertEqual(arguments.firstIndex(of: "-b:v").map { arguments[$0 + 1] }, "0", encoder.rawValue)
        }
        for encoder in [FFmpegEncoder.libx264, .libx265, .prores_ks, .h264_videotoolbox, .hevc_videotoolbox, .h264_amf] {
            XCTAssertTrue(encoder.defaultQualityArguments.isEmpty, encoder.rawValue)
        }
    }
}
