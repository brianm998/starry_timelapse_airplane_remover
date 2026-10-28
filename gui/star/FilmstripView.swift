import SwiftUI
import StarCore

// the filmstrip at the bottom

struct FilmstripView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        HStack {
            ScrollViewReader { scroller in
                if viewModel.imageSequenceSize == 0 {
                    Text(localized("ui.loading_film_strip"))
                      .font(.largeTitle)
                      .frame(minHeight: 50)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(0..<viewModel.imageSequenceSize, id: \.self) { frameIndex in
                                FilmstripImageView(frameIndex: frameIndex)
                                  .help(localized("ui.show_frame_n", frameIndex))
                            }
                        }
                    }
                      .defaultScrollAnchor(.center)
                      .onChange(of: viewModel.currentIndex, initial: true) {
                          scroller.scrollTo(viewModel.currentIndex)
                      }
                      .frame(minHeight: CGFloat((viewModel.config.config().thumbnailHeight) + 30))
                }
            }
        }
          .frame(maxWidth: .infinity, maxHeight: 50)
          .background(viewModel.imageSequenceSize == 0 ? .yellow : .clear)
    }
}



// MARK: frames that are still being extracted from a video

/// The band along the scrub slider's track showing which frames are extracted, as a video player shows what is buffered: the user can see
/// where they can go without waiting.
struct ExtractedRangesBand: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        let total = max(1, viewModel.imageSequenceSize)
        let ranges = Array(viewModel.extractedFrames.rangeView)
        return Canvas { context, size in
            // the unextracted part of the track, dimmed; the extracted part lit
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.35)))
            for range in ranges {
                let x0 = size.width * CGFloat(range.lowerBound) / CGFloat(total)
                let x1 = size.width * CGFloat(range.upperBound) / CGFloat(total)
                context.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)),
                             with: .color(.green.opacity(0.8)))
            }
        }
          .frame(height: 4)
          .clipShape(Capsule())
          .accessibilityIdentifier("extraction.band")
          .allowsHitTesting(false)
    }
}

/// A compact strip while a video is being extracted: a bar and "Extracting video: 1,234 of 5,000 frames (about 4 min left)".  Gone when it
/// finishes; an error that stays when it fails.
struct ExtractionProgressStripView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        if let error = viewModel.extractionError {
            Text(localized("ui.extraction_failed", error))
              .foregroundColor(.red)
              .font(.callout)
              .accessibilityIdentifier("extraction.error")
        } else if viewModel.isExtractingFrames, let progress = viewModel.extractionProgress {
            HStack(spacing: 8) {
                ProgressView(value: Double(progress.extracted), total: Double(max(1, progress.total)))
                  .frame(maxWidth: 240)
                  .accessibilityIdentifier("extraction.progress")
                Text(Self.text(for: progress))
                  .font(.callout)
                  .foregroundColor(.white)
            }
        }
    }

    static func text(for progress: FrameExtractionProgress) -> String {
        var text = localized("ui.extracting_video_progress",
                             progress.extracted.formatted(), progress.total.formatted())
        if let seconds = progress.estimatedSecondsRemaining {
            text += " (" + localized("ui.extracting_video_eta", durationText(seconds)) + ")"
        }
        return text
    }
}

/// "5 s", "4 min", "1 h 20 min": about how long, in the unit that reads best.
func durationText(_ seconds: Double) -> String {
    let rounded = Int(seconds.rounded(.up))
    if rounded < 90 { return "\(max(1, rounded)) s" }
    let minutes = Int((Double(rounded) / 60).rounded())
    if minutes < 90 { return "\(minutes) min" }
    return "\(minutes / 60) h \(minutes % 60) min"
}

/// What the main frame area shows in place of a frame that is not extracted yet: how long it will probably be, with a progress indicator.
///
/// Refreshed about once a second from the source, never from the view body.
struct FrameWaitPanelView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    @State private var eta: Double?
    @State private var swept = 0
    @State private var beingJumpedTo = false
    @State private var fraction = 0.0

    var body: some View {
        let index = viewModel.currentIndex
        return VStack(spacing: 10) {
            Text(localized("ui.frame_not_extracted", index.formatted()))
              .font(.title2)
              .foregroundColor(.white)
            if beingJumpedTo || viewModel.frameSource?.progress.accessKind == .seekable {
                // being fetched now
                if let eta {
                    Text(localized("ui.frame_extracting_now", durationText(eta)))
                      .foregroundColor(.white)
                    ProgressView(value: min(1, max(0, fraction)))
                      .frame(width: 260)
                } else {
                    Text(localized("ui.frame_extraction_estimating")).foregroundColor(.white)
                    ProgressView().frame(width: 260)
                }
            } else {
                // a long-GOP video that is extracted in order
                if let eta {
                    Text(localized("ui.frame_extraction_in_order", swept.formatted(), durationText(eta)))
                      .foregroundColor(.white)
                    ProgressView(value: min(1, max(0, fraction)))
                      .frame(width: 260)
                } else {
                    Text(localized("ui.frame_extraction_estimating")).foregroundColor(.white)
                    ProgressView().frame(width: 260)
                }
                Text(localized("ui.frame_extraction_in_order_reason"))
                  .font(.caption)
                  .foregroundColor(.secondary)
            }
        }
          .padding(24)
          .background(.black.opacity(0.7))
          .cornerRadius(10)
          // The whole frame area, not just the card: nothing underneath (the horizon painter, the outlier tools) can be clicked or
          // dragged on a frame that is not there.
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.black.opacity(0.35))
          .contentShape(Rectangle())
          .gesture(DragGesture(minimumDistance: 0))
          .accessibilityIdentifier("extraction.waitpanel")
          .task(id: index) {
              while !Task.isCancelled {
                  refresh(index)
                  try? await Task.sleep(nanoseconds: 1_000_000_000)
              }
          }
    }

    @MainActor private func refresh(_ index: Int) {
        guard let source = viewModel.frameSource else { return }
        eta = source.estimatedSecondsUntilAvailable(index)
        beingJumpedTo = source.isBeingJumpedTo(index)
        let head = source.sweepHead ?? 0
        swept = head
        if beingJumpedTo, let eta, eta > 0 {
            // the time left against the time it was first thought to take
            fraction = fraction == 0 ? 0.05 : max(fraction, 1 - eta / max(eta, 1))
        } else if index > 0 {
            fraction = min(1, Double(head) / Double(index))
        }
    }
}
