import SwiftUI
import StarCore
import logging


struct BlobProcessingView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    @State var detectionType: DetectionType? = nil
    
    var body: some View {
        @Bindable var viewModel = viewModel
        
        Group {
            if let viewModel = viewModel.imageSequence {
                self.mainView
            } else {
                VStack {
                    Text("No Image sequence loaded.")
                    Text("Load an image sequence in the main star window to see and edit blob processing steps here")
                }
            }
        }
          .navigationTitle("Star Blob Processing")
          .onAppear {
              Task.detached {
                  await constants.didChange() { detectionType in
                      Task { @MainActor in
                          self.detectionType = detectionType
                      }
                  }
              }
          }
    }

    var mainView: some View {
        VStack {
            Text("Blob Processing Steps")

            if let detectionType {
                Text("Currently using \(detectionType.rawValue) detection type")
                /*
                 read list of steps from processor, and show them to the user in a
                 scrollable list
                 
                 */
                ScrollView {
                    ForEach(detectionType.blobProcessor.steps, id: \.self) { step in 
                        Text("STEP \(step)")
                    }
                }
            }
        }
    }
}
