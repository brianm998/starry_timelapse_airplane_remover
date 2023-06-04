import SwiftUI
import StarCore

// this button clears everything

struct ClearAllButton: View {
    let contentView: ContentView

    var body: some View {
        Button(action: {
            contentView.imageSequenceView.setAllCurrentFrameOutliers(to: false, renderImmediately: false)
        }) {
            Text("Clear All")
        }
          .help("don't paint any of the outlier groups in the frame")
    }
}
