//
//  ContentView.swift
//  star
//
//  Created by Brian Martin on 2/1/23.
//

import Foundation
import SwiftUI
import Cocoa
import StarCore


// the overall view of the app
@available(macOS 13.0, *) 
struct ContentView: View {
    @ObservedObject var viewModel: ViewModel
    let imageSequenceView: ImageSequenceView
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel
        self.imageSequenceView = ImageSequenceView(viewModel: viewModel)
    }
    
    var body: some View {
        //let scaling_anchor = UnitPoint(x: 0.75, y: 0.75)
        if !viewModel.sequenceLoaded {
            InitialView(viewModel: viewModel)
        } else {
            self.imageSequenceView
        }
    }
}

@available(macOS 13.0, *) 
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: ViewModel())
    }
}

extension AnyTransition {
    static var moveAndFade: AnyTransition {
        //AnyTransition.move(edge: .trailing)
        //AnyTransition.slide
        .asymmetric(
          insertion: .move(edge: .trailing).combined(with: .opacity),
          removal: .scale.combined(with: .opacity)
        )         

    }
}
