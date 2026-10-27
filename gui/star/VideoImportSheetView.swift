import SwiftUI
import StarCore
import logging

/// A video the user has chosen, waiting for them to say how its frames are to be written.
struct PendingVideoImport: Identifiable {
    let path: String
    var id: String { path }
}

/// What the import sheet answers: how the frames are written, and whether the main screen opens
/// while they are still being extracted.
struct VideoImportOptions {
    var format: FrameDecodeFormat
    var extractInBackground: Bool
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
                    onImport(VideoImportOptions(format: format, extractInBackground: extractInBackground))
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
