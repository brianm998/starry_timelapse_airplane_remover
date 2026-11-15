import SwiftUI

import StarCore
struct FinderStyleDropZone: View {
    @State private var isTargeted = false
    var onDropAction: ([NSItemProvider]) -> Void
    /// A click on the zone, which the desktop client's zone has too: it opens the image sequence chooser.
    var onTap: () -> Void = {}

    /// The picture in the zone: the catching robot while a file is dragged over it, the drop target otherwise.
    static func art(isTargeted: Bool) -> StarArt {
        isTargeted ? .dropHover : .drop
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5]))
                .foregroundColor(isTargeted ? Color.accentColor : .white/*Color.secondary*/)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .shadow(color: isTargeted ? Color.accentColor.opacity(0.7) : Color.clear,
                        radius: isTargeted ? 8 : 0)
                .animation(.easeInOut(duration: 0.15), value: isTargeted)

            VStack(spacing: 6) {
                // Both pictures sit in the same 96 pt box, so the zone keeps its size when one replaces the other.
                ArtImage(FinderStyleDropZone.art(isTargeted: isTargeted))
                    .frame(width: 96, height: 96)
                Text(localized("ui.drop_a_video_an_image_sequence_or_an"))
                  .foregroundColor(.white)
                    .font(.headline)
            }
        }
        .frame(minWidth: 280, minHeight: 150)
        .padding()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .help(localized("ui.load_an_image_sequence_yet_to_be_processed"))
        .accessibilityIdentifier("startup.dropzone")
        .onDrop(of: ["public.file-url"], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        onDropAction(providers)
    }
}
