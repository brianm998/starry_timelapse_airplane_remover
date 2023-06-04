import SwiftUI
import StarCore

// this button paints everything

struct PaintAllButton: View {
    let contentView: ContentView

    var body: some View {
        Button(action: {
            contentView.imageSequenceView.setAllCurrentFrameOutliers(to: true, renderImmediately: false)
        }) {
            Text("Paint All")
        }
          .help("paint all of the outlier groups in the frame")
    }
}
