import SwiftUI
import StarCore
import logging

/// A video the user has chosen, waiting for them to say how its frames are to be written.
struct PendingVideoImport: Identifiable {
    let path: String
    var id: String { path }
}

/// An image sequence the user has chosen, waiting for them to say where its output and working files go.
struct PendingSequenceOpen: Identifiable {
    let path: String
    var id: String { path }
}

/// What the import sheet answers: how the frames are written, and whether the main screen opens
/// while they are still being extracted.  `outputDir` is where the frames, the output and the
/// working files go, nil being beside the video.
struct VideoImportOptions {
    var format: FrameDecodeFormat
    var extractInBackground: Bool
    var outputDir: String? = nil
}

/// Asks how the frames of a video are to be written (16 bit or 8 bit tiff, or jpeg and how good),
/// and how much disk that will take when the video's size is known, before any of it is decoded.
/// Also whether to go on to the main screen while the frames are still being extracted.
struct VideoImportSheetView: View {
    let pending: PendingVideoImport
    let onImport: (VideoImportOptions) -> Void
    let onCancel: () -> Void

    @State private var kind: FrameDecodeFormat.Kind = .tiff16
    @State private var jpegQuality: Double = Double(FrameDecodeFormat.defaultJPEGQuality)
    @State private var tiffCompression: FrameDecodeFormat.TIFFCompression = FrameDecodeFormat.defaultTIFFCompression
    @State private var probe: VideoProbe? = nil
    @State private var extractInBackground = false
    @State private var outputDir: String? = nil
    /// Once the user has touched the checkbox, what the probe finds no longer changes it.
    @State private var extractInBackgroundChosen = false

    private var format: FrameDecodeFormat {
        FrameDecodeFormat(kind: kind, jpegQuality: Int(jpegQuality.rounded()), tiffCompression: tiffCompression)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localized("ui.video_import_title")).font(.title)
            Text((pending.path as NSString).lastPathComponent).font(.headline)
            Text(localized("ui.video_import_blurb")).fixedSize(horizontal: false, vertical: true)

            Picker(localized("ui.video_frame_format"), selection: $kind) {
                Text(localized("ui.frame_format_tiff16")).tag(FrameDecodeFormat.Kind.tiff16)
                  .accessibilityIdentifier("videoimport.format.tiff16")
                Text(localized("ui.frame_format_tiff8")).tag(FrameDecodeFormat.Kind.tiff8)
                  .accessibilityIdentifier("videoimport.format.tiff8")
                Text(localized("ui.frame_format_jpeg")).tag(FrameDecodeFormat.Kind.jpeg)
                  .accessibilityIdentifier("videoimport.format.jpeg")
            }
              .pickerStyle(.radioGroup)

            if kind == .jpeg {
                HStack {
                    Text(localized("ui.jpeg_quality", Int(jpegQuality.rounded())))
                      .frame(minWidth: 110, alignment: .leading)
                    Slider(value: $jpegQuality,
                           in: Double(FrameDecodeFormat.jpegQualityRange.lowerBound)...Double(FrameDecodeFormat.jpegQualityRange.upperBound),
                           step: 1)
                }
            }

            if kind != .jpeg {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(localized("ui.tiff_compression"), selection: $tiffCompression) {
                        Text(localized("ui.tiff_compression_none")).tag(FrameDecodeFormat.TIFFCompression.none)
                          .accessibilityIdentifier("videoimport.compression.none")
                        Text(localized("ui.tiff_compression_packbits")).tag(FrameDecodeFormat.TIFFCompression.packBits)
                          .accessibilityIdentifier("videoimport.compression.packbits")
                    }
                      .pickerStyle(.radioGroup)
                    Text(localized("ui.tiff_compression_help"))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                }
            }

            diskUsage

            let frameBytes = probe?.estimatedBytes(for: format)
            WorkingLocationSectionView(
              source: pending.path,
              outputDir: $outputDir,
              inputBytes: frameBytes.map { UInt64(max($0, 0)) },
              frameBytes: frameBytes.map { UInt64(max($0, 0)) })

            // On by default where any frame can be had cheaply (ProRes and other intra-only formats); the help text says why
            // it is off for H.264 and the like.
            VStack(alignment: .leading, spacing: 4) {
                Toggle(localized("ui.video_import_background"), isOn: Binding(
                  get: { extractInBackground },
                  set: { extractInBackground = $0; extractInBackgroundChosen = true }))
                  .accessibilityIdentifier("videoimport.background")
                  .help(localized("ui.video_import_background_help"))
                Text(localized("ui.video_import_background_help"))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(localized("ui.cancel"), action: onCancel)
                  .keyboardShortcut(.cancelAction)
                Button(localized("ui.video_import_start")) {
                    onImport(VideoImportOptions(format: format, extractInBackground: extractInBackground, outputDir: outputDir))
                }
                  .keyboardShortcut(.defaultAction)
                  .accessibilityIdentifier("videoimport.import")
            }
        }
          .padding(24)
          .frame(width: 500)
          .task {
              // The codec's name settles the checkbox's default at once; the quick read of the packets then makes it exact.
              let path = pending.path
              probe = await Task.detached { VideoProbe.probe(videoAt: path) }.value
              if !extractInBackgroundChosen, let probe { extractInBackground = probe.extractInBackgroundByDefault }
          }
    }

    @ViewBuilder private var diskUsage: some View {
        if let probe, let bytes = probe.estimatedBytes(for: format), let frames = probe.frameCount {
            Text(localized("ui.video_import_disk_usage",
                           ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                           frames, probe.width, probe.height))
              .font(.callout)
              .fixedSize(horizontal: false, vertical: true)
        } else if probe != nil {
            Text(localized("ui.video_import_disk_unknown"))
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Where the output, the working files and (for a video) the extracted frames go, with what that will take and what the volume has
/// free, so the user can see whether it fits before agreeing.  `outputDir` nil is beside the `source`.
///
/// `inputBytes` is what the run is sized by: the sequence's own images, or the frames the video will be extracted to.  The extraction
/// itself is `frameBytes` (video only), which lands on the same volume and so counts toward what is needed.  Either nil is "not known",
/// and no total is shown.
struct WorkingLocationSectionView: View {
    let source: String
    @Binding var outputDir: String?
    let inputBytes: UInt64?
    var frameBytes: UInt64? = nil

    @State private var available: UInt64?? = nil   // nil while being read, .some(nil) when the volume would not say

    private var effectiveFolder: String {
        outputDir ?? (source as NSString).deletingLastPathComponent
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var processingBytes: UInt64? {
        inputBytes.map { UInt64(Double($0) * DiskSpaceCheck.peakToInputRatio) }
    }

    private var totalBytes: UInt64? {
        processingBytes.map { $0 + (frameBytes ?? 0) }
    }

    private var shortfall: UInt64? {
        guard let total = totalBytes, case let .some(.some(free)) = available, total > free else { return nil }
        return total - free
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("ui.location_title")).font(.headline)
            Text(localized("ui.location_blurb"))
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Text(effectiveFolder)
              .font(.callout)
              .lineLimit(1)
              .truncationMode(.middle)
              .accessibilityIdentifier("location.folder")
            HStack {
                Button(localized("ui.location_choose"), action: choose)
                  .accessibilityIdentifier("location.choose")
                if outputDir != nil {
                    Button(localized("ui.location_beside")) { outputDir = nil }
                      .accessibilityIdentifier("location.reset")
                }
            }
            if let total = totalBytes, let processing = processingBytes {
                if let frames = frameBytes {
                    Text(localized("ui.location_needed_video", format(total), format(frames), format(processing)))
                      .font(.callout)
                      .accessibilityIdentifier("location.needed")
                } else {
                    Text(localized("ui.location_needed", format(total)))
                      .font(.callout)
                      .accessibilityIdentifier("location.needed")
                }
            }
            switch available {
            case .none:
                EmptyView()
            case .some(.none):
                Text(localized("ui.location_unknown_free")).font(.callout).foregroundStyle(.secondary)
            case .some(.some(let free)):
                Text(localized("ui.location_available", format(free)))
                  .font(.callout)
                  .accessibilityIdentifier("location.available")
            }
            if let short = shortfall {
                Text(localized("ui.location_short", format(short)))
                  .font(.callout)
                  .foregroundStyle(.red)
                  .fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("location.short")
            }
        }
          .task(id: effectiveFolder) {
              let folder = effectiveFolder
              available = .some(await Task.detached { DiskSpaceCheck.availableBytes(forPath: folder) }.value)
          }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = localized("ui.location_title")
        panel.directoryURL = URL(fileURLWithPath: effectiveFolder, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { outputDir = url.path }
    }
}

/// Asked before an image sequence is opened (the counterpart of `VideoImportSheetView`, which has this in it for a video): where its
/// output and working files go, with what they will take, sized from the images in the folder, and what the volume has free.
struct SequenceLocationSheetView: View {
    let pending: PendingSequenceOpen
    let onOpen: (_ outputDir: String?) -> Void
    let onCancel: () -> Void

    @State private var outputDir: String? = nil
    @State private var inputBytes: UInt64? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localized("ui.sequence_location_title")).font(.title)
            Text((pending.path as NSString).lastPathComponent).font(.headline)
            WorkingLocationSectionView(source: pending.path, outputDir: $outputDir, inputBytes: inputBytes)
            HStack {
                Spacer()
                Button(localized("ui.cancel"), action: onCancel)
                  .keyboardShortcut(.cancelAction)
                Button(localized("ui.sequence_location_open")) { onOpen(outputDir) }
                  .keyboardShortcut(.defaultAction)
                  .accessibilityIdentifier("sequencelocation.open")
            }
        }
          .padding(24)
          .frame(width: 500)
          .task {
              // Stat-ing thousands of images is not for the main thread.
              let path = pending.path
              inputBytes = await Task.detached { DiskSpaceCheck.sequenceInputBytes(inDirectory: path) }.value
          }
    }
}
