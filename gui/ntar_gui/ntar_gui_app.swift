//
//  ntar_guiApp.swift
//  ntar_gui
//
//  Created by Brian Martin on 2/1/23.
//

import SwiftUI
import NtarCore

actor FramesToCheck {
    var frames: [FrameAirplaneRemover] = []

    func remove(frame: FrameAirplaneRemover) {
        Log.e("FFF REMOVE \(frames.count)")
        for i in 0..<frames.count {
            if frames[i].frame_index == frame.frame_index {
                frames.remove(at: i)
                break
            }
        }
        Log.e("FFF AFTER REMOVE \(frames.count)")
    }
    
    func append(frame: FrameAirplaneRemover) {
        // XXX append them in frame order
        self.frames.append(frame)
    }

    func count() -> Int {
        return self.frames.count
    }

    func nextFrame() -> FrameAirplaneRemover? {
        //Log.e("NEXT FRAME \(frames.count)")
        if frames.count == 0 { return nil }
        return frames[0]
    }
}

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

    var framesToCheck = FramesToCheck()

    // the state of each frame indexed by frame #
    var frame_states: [Int: FrameProcessingState] = [:]
    
    required init() {
        viewModel = ViewModel(framesToCheck: framesToCheck)
        Log.handlers[.console] = ConsoleLogHandler(at: .debug)
        Log.w("Starting Up")

        var use_json = true

        if use_json {
            // this path reads a saved json config file, along with potentially
            // a set of saved outlier groups for each frame
            
            let outlier_dirname = "/pp/tmp/LRT_12_22_2022-a9-2-aurora-topaz-ntar-v-0_1_3-outliers"
            //let outlier_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_small_medium-ntar-v-0_1_3-outliers"

            //let outlier_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_a7sii_100-ntar-v-0_1_3-outliers"
            
            outlier_json_startup(with: outlier_dirname)
            
        } else {
            // this path starts from a image sequence only
            
            // XXX take this from the input somehow
            //let image_sequence_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_small_medium"
            let image_sequence_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_small_lots"
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

                let callbacks = make_callbacks()
                
                let eraser = try NighttimeAirplaneRemover(with: config, callbacks: callbacks)
                self.viewModel.eraser = eraser // XXX rename this crap
                
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
                                writeOutlierGroupFiles: self.should_write_outlier_group_files)

            let callbacks = make_callbacks()
            Log.i("have config")
            do {
                let eraser = try NighttimeAirplaneRemover(with: config, callbacks: callbacks)
                //                        await Log.dispatchGroup = eraser.dispatchGroup.dispatch_group
                self.viewModel.eraser = eraser // XXX rename this crap
                //                            try eraser.run()

                Log.i("done running")
                
            } catch {
                Log.e("\(error)")
            }
        }
    }

    func make_callbacks() -> Callbacks {
        var callbacks = Callbacks()
        // count numbers here for max running 
        callbacks.countOfFramesToCheck = {
            let count = await self.framesToCheck.count()
            Log.i("XXX count \(count)")
            return count
        }

        
        callbacks.frameStateChangeCallback = { frame, state in
            // XXX do something here
            Log.d("frame \(frame.frame_index) changed to state \(state)")
            Task {
                await MainActor.run {
                    self.frame_states[frame.frame_index] = state
                    self.condense_frame_states_into_view_model()
                    self.viewModel.objectWillChange.send()
                }
            }
        }
        
        callbacks.frameCheckClosure = { new_frame in
            Log.d("frameCheckClosure for frame \(new_frame.frame_index)")
            Task {
                await self.framesToCheck.append(frame: new_frame)
                if let frame = await self.framesToCheck.nextFrame() {
                    Log.d("frameCheckClosure 3")
                    Log.i("got frame index \(frame)")
                    do {
                        Log.d("frameCheckClosure 4")
                        if let baseImage = try await frame.baseImage() {
                            self.viewModel.image = Image(nsImage: baseImage)
                            self.viewModel.frame = frame
                            await self.viewModel.update()
                            
                            Log.d("XXX self.viewModel.image = \(self.viewModel.image)")
                            // Perform UI updates
                        }
                    } catch {
                        Log.e("\(error)")
                    }
                } 
            }
        }
        return callbacks
    }
    
    // change the mapping of frame to state
    // to a mapping of state to frame count,
    // and put it in the view model
    func condense_frame_states_into_view_model() {
        viewModel.number_unprocessed = 0
        viewModel.number_loadingImages = 0
        viewModel.number_detectingOutliers = 0
        viewModel.number_readyForInterFrameProcessing = 0
        viewModel.number_interFrameProcessing = 0
        viewModel.number_outlierProcessingComplete = 0
        // XXX add gui check step?
        viewModel.number_reloadingImages = 0
        viewModel.number_painting = 0
        viewModel.number_writingOutputFile = 0
        viewModel.number_complete = 0
        
        for (frame_index, state) in frame_states {
            switch state {
            case .unprocessed:
                viewModel.number_unprocessed += 1
            case .loadingImages:    
                viewModel.number_loadingImages += 1
            case .detectingOutliers:
                viewModel.number_detectingOutliers += 1
            case .readyForInterFrameProcessing:
                viewModel.number_readyForInterFrameProcessing += 1
            case .interFrameProcessing:
                viewModel.number_interFrameProcessing += 1
            case .outlierProcessingComplete:
                viewModel.number_outlierProcessingComplete += 1
                // XXX add gui check step?
                // XXX add gui check step?
            case .reloadingImages:
                viewModel.number_reloadingImages += 1
            case .painting:
                viewModel.number_painting += 1
            case .writingOutputFile:
                viewModel.number_writingOutputFile += 1
            case .complete:
                viewModel.number_complete += 1
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}

fileprivate let file_manager = FileManager.default
