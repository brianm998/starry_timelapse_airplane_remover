//
//  ntar_guiApp.swift
//  ntar_gui
//
//  Created by Brian Martin on 2/1/23.
//

import SwiftUI
import NtarCore

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


    // XXX
    var imageView = ImageView()
    
    required init() {
        Log.handlers[.console] = ConsoleLogHandler(at: .debug)
        Log.w("Starting Up")

        // XXX take this from the input somehow
        image_sequence_dirname = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/test_small_medium"
        
        // XXX copied from Ntar.swift
        if var input_image_sequence_dirname = image_sequence_dirname {

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
            if let outputPath = outputPath {
                output_path = outputPath
            } else {
                output_path = input_image_sequence_path
            }

            var test_paint_output_path = output_path
            if let testPaintOutputPath = testPaintOutputPath {
                test_paint_output_path = testPaintOutputPath
            }

            var config = Config(outputPath: output_path,
                                outlierMaxThreshold: outlierMaxThreshold,
                                outlierMinThreshold: outlierMinThreshold,
                                minGroupSize: minGroupSize,
                                numConcurrentRenders: numConcurrentRenders,
                                test_paint: test_paint,
                                test_paint_output_path: test_paint_output_path,
                                imageSequenceName: input_image_sequence_name,
                                imageSequencePath: input_image_sequence_path,
                                writeOutlierGroupFiles: should_write_outlier_group_files)


            // XXX count numbers here for max running too
            config.frameCheckClosure = { frame in
                Task {
                    Log.i("got frame index \(frame)")
                    do {
                        if let baseImage = try await frame.baseImage() {
                            self.imageView.image = Image(nsImage: baseImage)
                        }
                    } catch {
                        Log.e("\(error)")
                    }
                }
            }

            Log.i("have config")
            Task {
                do {
                    let eraser = try NighttimeAirplaneRemover(with: config)
                    await Log.dispatchGroup = eraser.dispatchGroup.dispatch_group
                    try eraser.run()

                    self.imageView.image = Image(systemName: "person")
                    
                    Log.i("done running")
                    
                } catch {
                    Log.e("\(error)")
                }
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
            ContentView(image: imageView)
        }
    }
}
