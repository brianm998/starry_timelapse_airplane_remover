//
//  starApp.swift
//  star
//
//  Created by Brian Martin on 2/1/23.
//

import SwiftUI
import StarCore

/*

 UI Improvements:
  - scroll back and forth through frames
  - don't finish frames until some number later
  - improve speed when still processing files
  - overlier hover to give paint reason and size
  - feature to split outlier groups apart
  - add ability to have selection work for just part of outlier group, or all like now
  - have streak detection take notice of user choices before processing further frames

  - add meteor detection phase, which the backend will use to accentuate this outlier

  - fix bug where zooming and selection gestures correspond
  - allow dark/light themes
  - the filmstrip doesn't update very quickly on its own
  - make it overwrite existing output files
  - fix final queue usage from UI so it doesn't crash by trying to save the same frame twice

  - allow showing changed frames too

  - try a play button for playing a preview
  - of both rendered and original

  - outlier groups get wrong when scrolling
    - kindof fixed it

  - let shift + forward and back move 10-100 spaces instead of one
  - shortcut to go to the beginning and to the end of the sequence
  - play button with frame rate slider

  - rename previews/scrub and add and preview size to config
  - add config option to write out previews of both original and modified images to file
  - upon load, use the previews if they exist

  - add a button that calls frame.outlierGroups() on all frames to load their outliers

  - have filmstrip show outlier group load status somehow
  
  NEW UI:

  - have a render all button
  - add filter options by frame state to constrain the filmstrip
  - make filmstrip sizeable by dragging the top of it
  - make it possible to play the video based upon previews
    - could be faster
  
  - add status flags for frames
    - don't have outliers
    - loading outliers
    - have outliers
    - saving

    - show progress in saving in UI


  - add slider for outlier opacity

  - add overlay grid which shows color based upon what kind of outliers are inside:
    - blank for nothing
    - green for only no paint
    - red for only paint
    - purple for both
    - configurable number of boxes on each axis

  - add frame number to all views
  - show number of outliers in each frame, of each type
  - feature to allow splitting up outliers that include both cloud and airplane
  - toggle to make outliers flash (either kind)
  - function to allow render of all frames that are not present and also those that have changed
  - add feature to fuzz out some outliers, such as light leak from airplanes into clouds
    without this, ghost airplanes are still seen, the bright parts of the streak are gone,
    but a halo around still persists.  XXX somehow detect this beforehand? XXX

  - refactor the view model class so that it doesn't crash when closed when processing 
    problem now is that we re-use the same view model class, need to create another properly

  - orange unknown outlier groups not clickable directly (but are clickable on arrows)
    check to see if selection works or not

 */


@main
class star_app: App {
    
    required init() {
        Task {
            for window in NSApp.windows {
                if window.title.hasPrefix("Outlier") {
                    window.close()
                }
            }
        }
        
        Log.handlers[.console] = ConsoleLogHandler(at: .warn)
        Log.i("Starting Up")
    }
    
    var body: some Scene {
        let viewModel = ViewModel()
        
        WindowGroup {
            ContentView(viewModel: viewModel)
        }.commands {
            StarCommands(viewModel: viewModel)
        }
        
        WindowGroup(id: "foobar") { // XXX hardcoded constant should be centralized
            OutlierGroupTable(viewModel: viewModel)
              { 
                  // XXX don't really care it's dismissed
              }
                
        } .commands {
              StarCommands(viewModel: viewModel)
        }
        // this shows up as stars and wand in the upper right of the menu bar
        // always there when app is running, even when another app is used
        MenuBarExtra {
            ScrollView {
                VStack(spacing: 0) {
                    // maybe add buttons show show the different windows?
                    // maybe show overall progress monitor of some type?
                    Text("Should really be doing something here")
                    Text("what exactly?")
                    Text("not sure")
                }
            }
        } label: {
            Label("star", systemImage: "wand.and.stars.inverse")
        }

    }
}

let OUTLIER_WINDOW_PREFIX = "Outliers"
let OTHER_WINDOW_TITLE = "\(OUTLIER_WINDOW_PREFIX) Group Information"   // XXX make this better

// allow intiazliation of an array with objects of some type that know their index
// XXX put this somewhere else
extension Array {
    public init(count: Int, elementMaker: (Int) -> Element) {
        self = (0 ..< count).map { i in elementMaker(i) }
    }
}



