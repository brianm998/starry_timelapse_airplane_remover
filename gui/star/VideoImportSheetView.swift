import SwiftUI
import StarCore
import logging

/// A video the user has chosen, waiting for them to say how its frames are to be written.
struct PendingVideoImport: Identifiable {
    let path: String
    var id: String { path }
}

/// Asks how the frames of a video are to be written (16 bit or 8 bit tiff, or jpeg and how good),
/// and how much disk that will take when the video's size is known, before any of it is decoded.
struct VideoImportSheetView: View {
    let pending: PendingVideoImport
    let onImport: (FrameDecodeFormat) -> Void
    let onCancel: () -> Void

    @State private var kind: FrameDecodeFormat.Kind = .tiff16
    @State private var jpegQuality: Double = Double(FrameDecodeFormat.defaultJPEGQuality)
    @State private var probe: VideoProbe? = nil

    private var format: FrameDecodeFormat {
        FrameDecodeFormat(kind: kind, jpegQuality: Int(jpegQuality.rounded()))
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

            diskUsage

            HStack {
                Spacer()
                Button(localized("ui.cancel"), action: onCancel)
                  .keyboardShortcut(.cancelAction)
                Button(localized("ui.video_import_start")) { onImport(format) }
                  .keyboardShortcut(.defaultAction)
                  .accessibilityIdentifier("videoimport.import")
            }
        }
          .padding(24)
          .frame(width: 460)
          .task {
              // a quick read of the header; the sheet is usable while it runs
              let path = pending.path
              probe = await Task.detached { VideoProbe.probe(videoAt: path) }.value
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
