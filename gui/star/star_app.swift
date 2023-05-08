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
 */

@main
class star_app: App {

    var outputPath: String?
    var outlierMaxThreshold: Double = 13
    var outlierMinThreshold: Double = 9
    var minGroupSize: Int = 80      // groups smaller than this are completely ignored
    var numConcurrentRenders: Int = ProcessInfo.processInfo.activeProcessorCount
    var should_write_outlier_group_files = true // XXX see what happens
    var process_outlier_group_images = false

    /*@StateObject*/ private var viewModel: ViewModel

    // the state of each frame indexed by frame #
    //var frame_states: [Int: FrameProcessingState] = [:]
    
//    let input_queue: FinalQueue

    required init() {
        
        let dispatch_handler = DispatchHandler()
//        input_queue = FinalQueue(max_concurrent: 200, // XXX get this number right
//                                 dispatchGroup: dispatch_handler)
/*
        _viewModel = StateObject(wrappedValue: {
                                     let ret = ViewModel()
                                     // ret.app = self
                                     return ret
                                     }())
 */
        self.viewModel = ViewModel()
        viewModel.app = self
        Task {
            for window in NSApp.windows {
                if window.title.hasPrefix("Outlier") {
                    window.close()
                }
            }
        }

        
//        Task(priority: .high) {
//            try await input_queue.start()
//        }
        
        Log.handlers[.console] = ConsoleLogHandler(at: .info)
        Log.i("Starting Up")

        /*
        var use_json = true

        if use_json {
            // this path reads a saved json config file, along with potentially
            // a set of saved outlier groups for each frame

            //let outlier_dirname = "/pp/tmp/TEST_12_22_2022-a9-2-aurora-topaz-500-star-v-0_1_3-outliers/config.json"

            let outlier_dirname = "/qp/star_validated/LRT_09_24_2022-a7iv-2-aurora-topaz-star-v-0_1_3-outliers/config.json"
            
            //let outlier_dirname = "/pp/tmp/LRT_12_22_2022-a9-2-aurora-topaz-star-v-0_2_0-outliers/config.json"
            //let outlier_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_small_lots-star-v-0_2_0-outliers/config.json"
            //let outlier_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_small_medium-star-v-0_1_3-outliers/config.json"

            //let outlier_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_a7sii_100-star-v-0_2_0-outliers/config.json"
            
            //let outlier_dirname = "/qp/tmp/LRT_09_24_2022-a7iv-2-aurora-topaz-star-v-0_1_3-outliers/config.json"

            //let outlier_dirname = "/rp/tmp/LRT_02_18_2023-a7sii-2-aurora-topaz-star-v-0_2_0-outliers/config.json"
            //let outlier_dirname = "/rp/tmp/LRT_02_18_2023-a7iv-2-aurora-topaz-star-v-0_2_0-outliers/config.json"
            
            
            startup(withConfig: outlier_dirname)
            
        } else {
            // this path starts from a image sequence only
            
            let image_sequence_dirname = "/pp/tmp/TEST_12_22_2022-a9-2-aurora-topaz-500"
            // XXX take this from the input somehow
            //let image_sequence_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_small_medium"
            //let image_sequence_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_small_lots"
            //let image_sequence_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_small_fix_error"
            //let image_sequence_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_a7sii_10"        
            //let image_sequence_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_a9_20"        
            startup(with: image_sequence_dirname)
            }
         */
    }

    func startup(withConfig json_config_filename: String) {
        Log.d("outlier_json_startup with \(json_config_filename)")
        // first read config from json
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()

        UserPreferences.shared.justOpened(filename: json_config_filename)
        
        Task {
            do {
                let config = try await Config.read(fromJsonFilename: json_config_filename)

                let callbacks = await make_callbacks()
                
                let eraser = try NighttimeAirplaneRemover(with: config,
                                                          callbacks: callbacks,
                                                          processExistingFiles: true,/*,
                                                                                       maxResidentImages: 32*/
                                                          fullyProcess: false,
                                                          isGUI: true)

                await MainActor.run {
                    self.viewModel.eraser = eraser // XXX rename this crap
                    self.viewModel.config = config
                    if let fp = eraser.final_processor {
                        self.viewModel.frameSaveQueue = FrameSaveQueue(fp)
                    } else {
                        fatalError("fucking fix this")
                    }
                }

                Log.d("outlier json startup done")
            } catch {
                Log.e("\(error)")
            }
            dispatchGroup.leave()
        }
        dispatchGroup.wait()
    }
    
    @MainActor func startup(withNewImageSequence image_sequence_dirname: String) {

        // XXX copied from star.swift
        var input_image_sequence_dirname = image_sequence_dirname 

        while input_image_sequence_dirname.hasSuffix("/") {
            // remove any trailing '/' chars,
            // otherwise our created output dir(s) will end up inside this dir,
            // not alongside it
            _ = input_image_sequence_dirname.removeLast()
        }

        if !input_image_sequence_dirname.hasPrefix("/") {
            let full_path =
              file_manager.currentDirectoryPath + "/" + 
              input_image_sequence_dirname
            input_image_sequence_dirname = full_path
        }
        
        var filename_paths = input_image_sequence_dirname.components(separatedBy: "/")
        var input_image_sequence_path: String = ""
        var input_image_sequence_name: String = ""
        if let last_element = filename_paths.last {
            filename_paths.removeLast()
            input_image_sequence_path = filename_paths.joined(separator: "/")
            if input_image_sequence_path.count == 0 { input_image_sequence_path = "/" }
            input_image_sequence_name = last_element
        } else {
            input_image_sequence_path = "/"
            input_image_sequence_name = input_image_sequence_dirname
        }

        var output_path = ""
        if let outputPath = self.outputPath {
            output_path = outputPath
        } else {
            output_path = input_image_sequence_path
        }

        var config = Config(outputPath: output_path,
                            outlierMaxThreshold: self.outlierMaxThreshold,
                            outlierMinThreshold: self.outlierMinThreshold,
                            minGroupSize: self.minGroupSize,
                            numConcurrentRenders: self.numConcurrentRenders,
                            imageSequenceName: input_image_sequence_name,
                            imageSequencePath: input_image_sequence_path,
                            writeOutlierGroupFiles: self.should_write_outlier_group_files,
                            writeFramePreviewFiles: self.should_write_outlier_group_files,
                            writeFrameProcessedPreviewFiles: self.should_write_outlier_group_files,
                            writeFrameThumbnailFiles: self.should_write_outlier_group_files)

        
        
        let callbacks = make_callbacks()
        Log.i("have config")

        do {
            let eraser = try NighttimeAirplaneRemover(with: config,
                                                      callbacks: callbacks,
                                                      processExistingFiles: true,
                                                      isGUI: true)

            self.viewModel.eraser = eraser // XXX rename this crap
            self.viewModel.config = config

            if let fp = eraser.final_processor {
                self.viewModel.frameSaveQueue = FrameSaveQueue(fp)
            } else {
                fatalError("fucking fix this")
            }
            
        } catch {
            Log.e("\(error)")
        }

    }

    @MainActor func make_callbacks() -> Callbacks {
        var callbacks = Callbacks()


        // get the full number of images in the sequcne
        callbacks.imageSequenceSizeClosure = { image_sequence_size in
            self.viewModel.image_sequence_size = image_sequence_size
            Log.i("read image_sequence_size \(image_sequence_size)")
            self.viewModel.set(numberOfFrames: image_sequence_size)
        }
        
        // count numbers here for max running
        // XXX this method is obsolete
        callbacks.countOfFramesToCheck = {
//            let count = await self.framesToCheck.count()
            //Log.i("XXX count \(count)")
            return 1//count
        }

        
        callbacks.frameStateChangeCallback = { frame, state in
            // XXX do something here
            Log.d("frame \(frame.frame_index) changed to state \(state)")
            Task {
                await MainActor.run {
                    //self.frame_states[frame.frame_index] = state
                    self.viewModel.objectWillChange.send()
                }
            }
        }

        // called when we should check a frame
        callbacks.frameCheckClosure = { new_frame in
            Log.d("frameCheckClosure for frame \(new_frame.frame_index)")

            // XXX we may need to introduce some kind of queue here to avoid hitting
            // too many open files on larger sequences :(
            Task {
//                await self.input_queue.add(atIndex: new_frame.frame_index) {
                    await self.addToViewModel(frame: new_frame)
//                }
            }
        }
        
        return callbacks
    }

    @MainActor func addToViewModel(frame new_frame: FrameAirplaneRemover) async {
        Log.d("addToViewModel(frame: \(new_frame.frame_index))")

        if self.viewModel.config == nil {
            // XXX why this doesn't work initially befounds me,
            // but without doing this here there is no config present...
            self.viewModel.config = self.viewModel.config
        }
        if self.viewModel.frame_width != CGFloat(new_frame.width) ||
           self.viewModel.frame_height != CGFloat(new_frame.height)
        {
            await MainActor.run {
                self.viewModel.frame_width = CGFloat(new_frame.width)
                self.viewModel.frame_height = CGFloat(new_frame.height)
            }
        }
        await self.viewModel.append(frame: new_frame)

       // Log.d("addToViewModel self.viewModel.frame \(self.viewModel.frame)")

        // is this the currently selected frame?
        if self.viewModel.current_index == new_frame.frame_index {
            self.viewModel.label_text = "frame \(new_frame.frame_index)"

            Log.i("got frame index \(new_frame.frame_index)")

            // XXX not getting preview here
            
            do {
                if let baseImage = try await new_frame.baseImage() {
                    if self.viewModel.current_index == new_frame.frame_index {
                        await MainActor.run {
                            Task {
                                self.viewModel.current_frame_image = Image(nsImage: baseImage)
                                self.viewModel.update()
                            }
                        }
                    }
                }
            } catch {
                Log.e("error")
            }

            //self.viewModel.frame = new_frame
            // Perform UI updates
            self.viewModel.update()
        } else {
            await MainActor.run {
                self.viewModel.objectWillChange.send()
            }
            // update view for thumbnails
        }
    }

    var body: some Scene {
        let contentView = ContentView(viewModel: viewModel)
        WindowGroup {
            contentView
        }
          .commands {
              CommandMenu("Actions") {
                  contentView.paintAllButton()
                    .keyboardShortcut("p", modifiers: [])
                  //.disabled(!viewModel.sequenceLoaded)

                  contentView.clearAllButton()
                    .keyboardShortcut("c", modifiers: [])

                  contentView.outlierInfoButton()
                  contentView.applyAllDecisionTreeButton()
                  contentView.applyDecisionTreeButton()
                  contentView.loadAllOutliersButton()
                  contentView.renderCurrentFrameButton()
                  contentView.renderAllFramesButton()
              }
              CommandMenu("Playback") {
                  Button("Show first frame") {
                      contentView.goToFirstFrameButtonAction()
                  }
                  Button("Go back many frames") {
                      contentView.fastPreviousButtonAction()
                  }
                  Button("Go back one frame") {
                      contentView.transition(numberOfFrames: -1)
                  }
                  Button(contentView.video_playing ? "Pause Video" : "Play Video") {
                      contentView.togglePlay()
                  }
                  Button("Advance one frame") {
                      contentView.transition(numberOfFrames: 1)
                  }
                  Button("Advance many frames") {
                      contentView.fastPreviousButtonAction()
                  }
                  Button("Show last frame") {
                      contentView.goToFirstFrameButtonAction()
                  }
              }
          }
        WindowGroup(id: "foobar") {
            OutlierGroupTable(viewModel: viewModel)
              { 
                  // XXX don't really care it's dismissed
              }
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

fileprivate let file_manager = FileManager.default
