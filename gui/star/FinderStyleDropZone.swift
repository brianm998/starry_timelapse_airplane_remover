import SwiftUI

import StarCore
struct FinderStyleDropZone: View {
    @State private var isTargeted = false
    var onDropAction: ([NSItemProvider]) -> Void

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
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 32))
                    .foregroundColor(.white)
                Text(localized("ui.drop_a_video_an_image_sequence_or_an"))
                  .foregroundColor(.white)
                    .font(.headline)
            }
        }
        .frame(minWidth: 280, minHeight: 150)
        .padding()
        .onDrop(of: ["public.file-url"], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        onDropAction(providers)
    }
}
