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
                ImageSequenceView()
                  .environment(imageSequenceViewModel)
                  .navigationTitle(imageSequenceViewModel.windowTitle)
            } else {
                InitialView()
            }
            if viewModel.showErrorAlert {
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
}

@available(macOS 13.0, *) 
struct ContentView_Previews: PreviewProvider {
    @Environment(ViewModel.self) var viewModel: ViewModel

    static var previews: some View {
        ContentView()
    }
}
