//
//  ntar_guiApp.swift
//  ntar_gui
//
//  Created by Brian Martin on 2/1/23.
//

import SwiftUI
import NtarCore

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
  - use something besides json for storying outlier groups to file?

  - use https://github.com/christophhagen/BinaryCodable instead of json for outlier groups

  - back/forward doesn't work on unloaded frames

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
  
  NEW UI:

  - have a render all button
  - add filter options by frame state to constrain the filmstrip
  - make filmstrip sizeable by dragging the top of it
  - make it possible to play the video based upon previews
 */

@main
class ntar_gui_app: App {

    var outputPath: String?
    var outlierMaxThreshold: Double = 13
    var outlierMinThreshold: Double = 9
    var minGroupSize: Int = 80      // groups smaller than this are completely ignored
    var numConcurrentRenders: Int = ProcessInfo.processInfo.activeProcessorCount
    var test_paint = false
    var testPaintOutputPath: String?
    var show_test_paint_colors = false
    var should_write_outlier_group_files = true // XXX see what happens
    var process_outlier_group_images = false
    var image_sequence_dirname: String?

    var viewModel: ViewModel

    // the state of each frame indexed by frame #
    var frame_states: [Int: FrameProcessingState] = [:]
    
    required init() {
        viewModel = ViewModel(framesToCheck: FramesToCheck())
        
        Log.handlers[.console] = ConsoleLogHandler(at: .debug)
        Log.i("Starting Up")

        var use_json = true

        if use_json {
            // this path reads a saved json config file, along with potentially
            // a set of saved outlier groups for each frame

            //let outlier_dirname = "/pp/tmp/TEST_12_22_2022-a9-2-aurora-topaz-500-ntar-v-0_1_3-outliers"
            
            //let outlier_dirname = "/pp/tmp/LRT_12_22_2022-a9-2-aurora-topaz-ntar-v-0_1_3-outliers"
            let outlier_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_small_medium-ntar-v-0_1_3-outliers"

            //let outlier_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_a7sii_100-ntar-v-0_1_3-outliers"
            
            //let outlier_dirname = "/qp/tmp/LRT_09_24_2022-a7iv-2-aurora-topaz-ntar-v-0_1_3-outliers"
            
            outlier_json_startup(with: outlier_dirname)
            
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
    }

    func outlier_json_startup(with outlier_dirname: String) {
        // first read config from json
        Task {
            do {
                let config = try await Config.read(fromJsonDirname: outlier_dirname)

                viewModel.config = config
                viewModel.framesToCheck.config = config

                let callbacks = make_callbacks()
                
                let eraser = try NighttimeAirplaneRemover(with: config,
                                                          callbacks: callbacks,
                                                          processExistingFiles: true,/*,
                                                                                       maxResidentImages: 32*/
                                                          fullyProcess: false)
                self.viewModel.eraser = eraser // XXX rename this crap

                if let fp = eraser.final_processor {
                    self.viewModel.frameSaveQueue = FrameSaveQueue(fp)
                } else {
                    fatalError("fucking fix this")
                }
                
            } catch {
                Log.e("\(error)")
            }
        }
    }
    
    func startup(with image_sequence_dirname: String) {

        self.image_sequence_dirname = image_sequence_dirname
        
        // XXX copied from Ntar.swift
        if var input_image_sequence_dirname = self.image_sequence_dirname {

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

            var test_paint_output_path = output_path
            if let testPaintOutputPath = self.testPaintOutputPath {
                test_paint_output_path = testPaintOutputPath
            }

            var config = Config(outputPath: output_path,
                                outlierMaxThreshold: self.outlierMaxThreshold,
                                outlierMinThreshold: self.outlierMinThreshold,
                                minGroupSize: self.minGroupSize,
                                numConcurrentRenders: self.numConcurrentRenders,
                                test_paint: self.test_paint,
                                test_paint_output_path: test_paint_output_path,
                                imageSequenceName: input_image_sequence_name,
                                imageSequencePath: input_image_sequence_path,
                                writeOutlierGroupFiles: self.should_write_outlier_group_files,
                                writeFramePreviewFiles: true,
                                writeFrameThumbnailFiles: true)


            viewModel.config = config
            viewModel.framesToCheck.config = config
            
            let callbacks = make_callbacks()
            Log.i("have config")
            do {
                let eraser = try NighttimeAirplaneRemover(with: config,
                                                          callbacks: callbacks,
                                                          processExistingFiles: true/*,
                                                          maxResidentImages: 32*/)
                //                        await Log.dispatchGroup = eraser.dispatchGroup.dispatch_group
                self.viewModel.eraser = eraser // XXX rename this crap
                //                            try eraser.run()


                if let fp = eraser.final_processor {
                    self.viewModel.frameSaveQueue = FrameSaveQueue(fp)
                } else {
                    fatalError("fucking fix this")
                }

                
                Log.i("done running")
                
            } catch {
                Log.e("\(error)")
            }
        }
    }

    func make_callbacks() -> Callbacks {
        var callbacks = Callbacks()


        // get the full number of images in the sequcne
        callbacks.imageSequenceSizeClosure = { image_sequence_size in
            self.viewModel.image_sequence_size = image_sequence_size
            Log.e("read image_sequence_size \(image_sequence_size)")
            self.viewModel.framesToCheck = FramesToCheck(number: image_sequence_size)
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
                    self.frame_states[frame.frame_index] = state
                    self.viewModel.objectWillChange.send()
                }
            }
        }

        // called when we should check a frame
        callbacks.frameCheckClosure = { new_frame in
            Log.d("frameCheckClosure for frame \(new_frame.frame_index)")
            Task {
                await self.addToViewModel(frame: new_frame)
            }
        }
        
        return callbacks
    }

    func addToViewModel(frame new_frame: FrameAirplaneRemover) async {
        Log.d("addToViewModel(frame: \(new_frame.frame_index))")

        if self.viewModel.framesToCheck.config == nil {
            // XXX why this doesn't work initially befounds me,
            // but without doing this here there is no config present...
            self.viewModel.framesToCheck.config = self.viewModel.config
        }
        
        await self.viewModel.framesToCheck.append(frame: new_frame, viewModel: self.viewModel)

        Log.d("addToViewModel self.viewModel.frame \(self.viewModel.frame)")

        // is this the currently selected frame?
        if self.viewModel.frame == nil,
           self.viewModel.framesToCheck.current_index == new_frame.frame_index
        {
            self.viewModel.label_text = "frame \(new_frame.frame_index)"

            Log.i("got frame index \(new_frame.frame_index)")

            // XXX not getting preview here
            
            do {
                if let baseImage = try await new_frame.baseImage() {
                    self.viewModel.image = Image(nsImage: baseImage)
                    await self.viewModel.update()
                }
            } catch {
                Log.e("error")
            }

            self.viewModel.frame = new_frame
            // Perform UI updates
            await self.viewModel.update()
            
            Log.d("XXX self.viewModel.image = \(self.viewModel.image)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}

// allow intiazliation of an array with objects of some type that know their index
// XXX put this somewhere else
extension Array {
    public init(count: Int, elementMaker: (Int) -> Element) {
        self = (0 ..< count).map { i in elementMaker(i) }
    }
}

fileprivate let file_manager = FileManager.default
