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
    var should_write_outlier_group_files = false
    var process_outlier_group_images = false
    var image_sequence_dirname: String?

    var viewModel: ViewModel

    var framesToCheck = FramesToCheck()
    
    required init() {
        viewModel = ViewModel(framesToCheck: framesToCheck)
        Log.handlers[.console] = ConsoleLogHandler(at: .debug)
        Log.w("Starting Up")

        // XXX take this from the input somehow
        //image_sequence_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_small_medium"
        image_sequence_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_small_fix_error"

        // XXX copied from Ntar.swift
        if var input_image_sequence_dirname = self.image_sequence_dirname {

            while input_image_sequence_dirname.hasSuffix("/") {
                // remove any trailing '/' chars,
                // otherwise our created output dir(s) will end up inside this dir,
                // not alongside it
                _ = input_image_sequence_dirname.removeLast()
            }

            var filename_paths = input_image_sequence_dirname.components(separatedBy: "/")
            var input_image_sequence_path: String = ""
            var input_image_sequence_name: String = ""
            if let last_element = filename_paths.last {
                filename_paths.removeLast()
                input_image_sequence_path = filename_paths.joined(separator: "/")
                if input_image_sequence_path.count == 0 { input_image_sequence_path = "." }
                input_image_sequence_name = last_element
            } else {
                input_image_sequence_path = "."
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
            // count numbers here for max running 
            config.countOfFramesToCheck = {
                let count = await self.framesToCheck.count()
                Log.i("XXX count \(count)")
                return count
            }

            config.frameCheckClosure = { new_frame in
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

            Log.i("have config")
            do {
                let eraser = try NighttimeAirplaneRemover(with: config)
                //                        await Log.dispatchGroup = eraser.dispatchGroup.dispatch_group
                self.viewModel.eraser = eraser // XXX rename this crap
                //                            try eraser.run()

                Log.i("done running")
                
            } catch {
                Log.e("\(error)")
            }
        }
        /*

         did:

         hard code some Config class
         
         use that to startup something similar to what Ntar.swift does on cli
         
         next steps:

         track this progress w/ the ui

         get it to show an image before painting with choices

         allow choices to be changed

         add paint button

         add more ui crap so it doesn't look like shit
         
         */
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}
