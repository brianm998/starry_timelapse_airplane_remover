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
        if viewModel.sequenceLoaded {
            ImageSequenceView()
        } else {
            InitialView()
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
