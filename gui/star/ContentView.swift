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

enum VideoPlayMode: String, Equatable, CaseIterable {
    case forward
    case reverse
}

enum FrameViewMode: String, Equatable, CaseIterable {
    case original
    case processed

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

enum SelectionMode: String, Equatable, CaseIterable {
    case paint
    case clear
    case details
    
    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

enum InteractionMode: String, Equatable, CaseIterable {
    case edit
    case scrub

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}





// the overall level of the app
@available(macOS 13.0, *) 
struct ContentView: View {
    @ObservedObject var viewModel: ViewModel
    let imageSequenceView: ImageSequenceView
    
    //@State private var previously_opened_sheet_showing = false
    @State private var previously_opened_sheet_showing_item: String =
      UserPreferences.shared.sortedSequenceList.count > 0 ?
      UserPreferences.shared.sortedSequenceList[0] : ""      

    init(viewModel: ViewModel) {
        self.viewModel = viewModel
        self.imageSequenceView = ImageSequenceView(viewModel: viewModel)
    }
    
    var body: some View {
        //let scaling_anchor = UnitPoint(x: 0.75, y: 0.75)
        if !viewModel.sequenceLoaded {
            InitialView(viewModel: viewModel,
                        previously_opened_sheet_showing_item: $previously_opened_sheet_showing_item)
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
