import SwiftUI
import StarCore

// a view that shows the current frame number being shown,
// and on double tap, allows editing of what number to show
struct EditableFrameNumberView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    @State private var editFrameNumberMode = false
    @State private var editFrameNumberModeString = ""
    
    var body: some View {
        let frameNumberString = String(format: "%d", viewModel.currentIndex)
        if self.editFrameNumberMode {
            HStack {
                Text("frame")
                TextField("\(frameNumberString)",
                          text: $editFrameNumberModeString)
                  .frame(maxWidth: 38)
                  .onSubmit {
                      let filtered = editFrameNumberModeString.filter { "0123456789".contains($0) }
                      if let newIntValue = Int(filtered),
                         newIntValue >= 0,
                         newIntValue < self.viewModel.imageSequenceSize
                      {
                          self.viewModel.currentIndex = newIntValue
                          self.editFrameNumberMode = false
                          self.editFrameNumberModeString = ""
                      }
                  }
            }
        } else {
            Text("frame \(frameNumberString)")
              .onTapGesture(count: 2) {
                  self.editFrameNumberMode = true
              }
        }
    }
}
