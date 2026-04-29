//
//  ContentView.swift
//  star
//
//  Created by Brian Martin on 2/1/23.
//

import SwiftUI

// the overall view of the app
@available(macOS 13.0, *) 
struct ContentView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    
    var body: some View {
        ZStack {
            if viewModel.isLoadingImageSequence {
                ImageSequenceLoadingView()
            } else if let imageSequenceViewModel = viewModel.imageSequence {
                CursorView(cursor: viewModel.cursor) {
                    ImageSequenceView()
                      .environment(imageSequenceViewModel)
                      .navigationTitle(imageSequenceViewModel.windowTitle)
                }
            } else {
                CursorView(cursor: viewModel.cursor) {
                    InitialView()
                }
            }
            // these may show on top
            if viewModel.showInfoDialog { InfoDialogView() }
            if viewModel.showErrorAlert { self.errorAlert }
            if viewModel.showCloseConfirmation { self.closeConfirmationAlert }

        }
    }

    var closeConfirmationAlert: some View {
        ZStack {
            Rectangle()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.gray)
              .opacity(0.5)

            VStack(spacing: 0) {
                Text("Work In Progress")
                  .font(.headline)
                  .padding(.bottom, 16)
                Text(viewModel.closeConfirmationMessage)
                  .multilineTextAlignment(.center)
                  .padding(.bottom, 24)
                HStack(spacing: 16) {
                    Button("Cancel") {
                        viewModel.showCloseConfirmation = false
                        viewModel.closeConfirmationAction = nil
                    }
                    Button("Stop and Close") {
                        let action = viewModel.closeConfirmationAction
                        viewModel.showCloseConfirmation = false
                        viewModel.closeConfirmationAction = nil
                        action?()
                    }
                    .foregroundColor(.red)
                }
            }
              .padding(40)
              .frame(maxWidth: 480)
              .background(.regularMaterial)
              .cornerRadius(16)
        }
    }

    var errorAlert: some View {
        ZStack {
            Rectangle()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.gray)
              .opacity(0.5)

            VStack {
                Text("ERROR")
                
                Spacer()
                  .frame(maxHeight: 40)
                Text(viewModel.errorMessage)
                Spacer()
                  .frame(maxHeight: 40)
                Button() {
                    viewModel.showErrorAlert = false
                } label: {
                    Text("Close")
                }
            }
              .padding(40)
              .frame(maxWidth: 500)
              .background(.red)
              .cornerRadius(20)
        }
    }
}
