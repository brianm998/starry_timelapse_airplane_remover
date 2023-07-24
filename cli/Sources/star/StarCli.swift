import Foundation
import ArgumentParser
import CoreGraphics
import Cocoa
import StarCore

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


/*
todo:

 - do star alignment with some 3rd party software: 
   https://www.startools.org/links--tutorials/free-image-stacking-solutions/sequator
   And then use aligned images to substitute pixels

 - FIX HANGING BUG
   This happens when all frames have been through detection,
   and for some yet unknown reason the app hangs forever without finishing
   stop and re-start works for now, but isn't ideal.
 
 - try image blending
 - make it faster (can always be faster) 
 - make crash detection perl script better
 - add scripts to allow video to processed video in one command
   - decompress existing video w/ ffmpeg (and note exactly how it was compressed)
   - process image sequence with star
   - recompress processed image sequence w/ ffmpeg with same parameters as before
   - remove image sequence dir
 - use the number of groups that have fallen into the same line group to boost its painting
 - output dirs are created even when intput filename is not existant

 - using too much memory problems :(
   better, but still uses lots of ram
   
 - specific out of memory issue with initial processing queue overloading the single final processing thread
   use some tool like this to avoid forcing a reboot:
   https://stackoverflow.com/questions/71209362/how-to-check-system-memory-usage-with-swift

 - try some kind of processing of individual groups that classifies them as plane or not
   either a hough transform to detect that it's cloas to a line, or detecting holes in them?
   i.e. the percentage of neighbors found, or the percentage without empty neighbors

 - restrict final pass processing to more uncertain choices (40%-60% initial score)?

 - use distance between frames when calculating positive final pass too.
   i.e. they shouldn't overlap, but shouldn't be too far away either

 - expand final processing to identify nearby groups that should be painted
   for example one frame has a known line, and next frame has another group
   w/ similar theta/rho that is not painted, but is the same object

 - make the info logging better

 - airplanes have:
   - a real line
   - often close but not too far from aligning line in adjecent frames
   - often have lots of pixels
   - pixels more likely to be packed closely together
   - if close to 1-1 aspect ratio, low fill amount
   - if close to line aspect ratio, high fill amount

 - non airplanes have:
   - fewer pixels
   - no real line
   - many holes in the structure
   - unlikely to have matching aligned groups in adjecent frames
   - same approx fill amount regardless of aspect ratio

 - make outlier output text files be separated by airplane / not airplane

 - apply the same center theta outlier logic to outliers within the same frame

 - find some way to ignore groups of the horizon, it's a problem for moving timelapses,
   can cause the background to skip badly
   perhaps detecting contrast changes on the edge?
   i.e. notice when neighboring pixels of the group are brighter on one side than the other.
 
 - figure out how distribution works
   - a .dmg file with a command line installer?  any swift command line installer examples?
   
 - there is a logging bug where both console and file need to be set to debug, otherwise the logfile
    is not accurate (has some debug, but not all) (
    
 - look into async file io

 - notice when disk fills up, and pause processing until able to save

 - speed up inter-frame analysis

 - make distance in FinalProcessor more accurate and faster

 - weight hough transform by brightness?
   need to redo-training histograms, they fail when we do this :(
 - redo histogram output to include brightness level of each pixel in outlier groups
 
 - instead of just taking the first line from the hough transform blindly, try a more statistical approach
   to validate how likely this line is

 - handle case where disk fills up better, right now it just keeps running but not saving anything
 - add feature to ensure available disk space before running (with command line disable)

 - updatable 'frames complete' wrong when re-starting an incomplete previous run

 - updatable 'awaiting inter-frame processing' doesn't show items past max concurrent

 - add a keep the meteor feature?
   specify what frame, and the bounds the meteor is in,
   and how many frames to keep it for
   Then detect the outlier, keep it, and blend it back in for that many frames

 - put warnings above updatable log

 - have 'frames complete' updatable log include skipped already existing files
   (without this, restarting shows the wrong number of complete frames)

 - on successful completion, overwrite updatable progress log with ascii art of night sky?

 - 12/22/2022 videos have false positives on clouds because of both assumed size and streak detection
   enhance streak detection to make sure the group center line between frames is close to the outlier
   groups hough line

 */


// do these really have to be globals?
var config: Config = Config()

var callbacks = Callbacks()

@main
struct StarCli: ParsableCommand {

    @Option(name: [.customShort("c"), .customLong("console-log-level")], help:"""
        The logging level that star will output directly to the terminal.
        """)
    var terminalLogLevel: Log.Level?/* = .info*/

    @Option(name: [.short, .customLong("file-log-level")], help:"""
        If present, star will output a file log at the given level.
        """)
    var fileLogLevel: Log.Level?

    @Option(name: [.short, .customLong("output-path")], help:"""
        The filesystem location under which star will create output dir(s).
        Defaults to creating output dir(s) alongside input sequence dir
        """)
    var outputPath: String?
    
    @Option(name: [.customShort("B"), .long], help: """
        The percentage in brightness increase necessary for a single pixel to be considered an outlier.
        Higher values decrease the number and size of found outlier groups.
        Lower values increase the size and number of outlier groups,
        which may find more airplanes, but also may yield more false positives.
        Outlier Pixels with brightness increases greater than this are fully painted over.
        """)
    var outlierMaxThreshold = Defaults.outlierMaxThreshold

    @Option(name: [.customShort("b"), .long], help: """
        The percentage in brightness increase for the lower threshold.
        This threshold is used to expand the size of outlier groups by neighboring pixels
        that have brightness changes above this threshold.
        Any outlier pixel that falls between this lower threshold and --outlier-max-threshold
        will be painted over with an alpha level betewen the two values,
        leaving some of the original pixel value present.
        """)
    var outlierMinThreshold = Defaults.outlierMinThreshold

    @Option(name: .shortAndLong, help: """
        The minimum outlier group size.  Outlier groups smaller than this will be ignored.
        Smaller values produce more groups, which may get more small airplane streaks,
        but also might end with more twinkling stars.
        """)
    var minGroupSize = Defaults.minGroupSize // groups smaller than this are completely ignored
    
    @Option(name: .shortAndLong, help: """
        Max Number of frames to process at once.
        The default of all cpus works good in most cases.
        May need to be reduced to a lower value if to consume less ram on some machines.
        """)
    // XXX this isn't respected when loading from a config
    var numConcurrentRenders: Int = ProcessInfo.processInfo.activeProcessorCount

    @Flag(name: [.customShort("w"), .customLong("write-outlier-group-files")],
          help:"Write individual outlier group image files")
    var shouldWriteOutlierGroupFiles = false

    @Flag(name: .shortAndLong, help:"Show version number")
    var version = false

    @Flag(name: .shortAndLong, help:"only write out outlier data, not images")
    var skipOutputFiles = false

    @Argument(help: """
        Image sequence dirname to process. 
        Should include a sequence of 16 bit tiff files, sortable by name.
        """)
    var imageSequenceDirname: String?


    mutating func run() throws {
        if version {
            print("""
                  Nighttime Timelapse Airplane Remover (star) version \(config.starVersion)
                  """)
            return
        }
        
        if var inputImageSequenceDirname = imageSequenceDirname {

            // XXX there is a bug w/ saved configs where the 'imageSequencePath' is '.'
            // and the 'imageSequenceDirname' starts with '/', won't start up properly
            
            var inputImageSequencePath: String = ""
            var inputImageSequenceName: String = ""
            if inputImageSequenceDirname.hasSuffix("config.json") {
                // here we are reading a previously saved config
                inputImageSequencePath = inputImageSequenceDirname

                let fuck = inputImageSequenceDirname
                
                let dispatchGroup = DispatchGroup()
                dispatchGroup.enter()

                Task {
                    do {
                        config = try await Config.read(fromJsonFilename: fuck)
                    } catch {
                        print("\(error)")
                    }
                    dispatchGroup.leave()
                }
                TaskRunner.maxConcurrentTasks = UInt(numConcurrentRenders)
                dispatchGroup.wait()
            } else {
                // here we are processing a new image sequence 
                while inputImageSequenceDirname.hasSuffix("/") {
                    // remove any trailing '/' chars,
                    // otherwise our created output dir(s) will end up inside this dir,
                    // not alongside it
                    _ = inputImageSequenceDirname.removeLast()
                }

                if !inputImageSequenceDirname.hasPrefix("/") {
                    let fullPath =
                      fileManager.currentDirectoryPath + "/" + 
                      inputImageSequenceDirname
                    inputImageSequenceDirname = fullPath
                }
                
                var filenamePaths = inputImageSequenceDirname.components(separatedBy: "/")
                if let lastElement = filenamePaths.last {
                    filenamePaths.removeLast()
                    inputImageSequencePath = filenamePaths.joined(separator: "/")
                    if inputImageSequencePath.count == 0 { inputImageSequencePath = "/" }
                    inputImageSequenceName = lastElement
                } else {
                    inputImageSequencePath = "/"
                    inputImageSequenceName = inputImageSequenceDirname
                }

                var _outputPath = ""
                if let outputPath = outputPath {
                    _outputPath = outputPath
                } else {
                    _outputPath = inputImageSequencePath
                }

                config = Config(outputPath: _outputPath,
                                outlierMaxThreshold: outlierMaxThreshold,
                                outlierMinThreshold: outlierMinThreshold,
                                minGroupSize: minGroupSize,
                                imageSequenceName: inputImageSequenceName,
                                imageSequencePath: inputImageSequencePath,
                                writeOutlierGroupFiles: shouldWriteOutlierGroupFiles,
                                // maybe make a separate command line parameter for these VVV? 
                                writeFramePreviewFiles: shouldWriteOutlierGroupFiles,
                                writeFrameProcessedPreviewFiles: shouldWriteOutlierGroupFiles,
                                writeFrameThumbnailFiles: shouldWriteOutlierGroupFiles)

                Log.nameSuffix = inputImageSequenceName
                // no name suffix on json config path
            }

            Log.name = "star-log"

            if let terminalLogLevel = terminalLogLevel {
                // use console logging
                Log.handlers[.console] = ConsoleLogHandler(at: terminalLogLevel)
            } else {
                // enable updatable logging when not doing console logging
                callbacks.updatable = UpdatableLog()

                if let updatable = callbacks.updatable {
                    Log.handlers[.console] = UpdatableLogHandler(updatable)
                    let name = inputImageSequenceName
                    let path = inputImageSequencePath
                    let message = "star v\(config.starVersion) is processing images from sequence in \(path)/\(name)"
                    Task {
                        await updatable.log(name: "star",
                                            message: message,
                                            value: -1)
                    }
                }
            }

            if let fileLogLevel = fileLogLevel {
                Log.i("enabling file logging")
                do {
                    Log.handlers[.file] = try FileLogHandler(at: fileLogLevel)
                } catch {
                    Log.e("\(error)")
                }
            }
            
            signal(SIGKILL) { foo in
                print("caught SIGKILL \(foo)")
            }
            
            Log.i("looking for files to processes in \(inputImageSequenceDirname)")
            let localDispatch = DispatchGroup()
            localDispatch.enter()
            let writeOutputFiles = !skipOutputFiles
            let max = numConcurrentRenders
            Task {
                do {
                    let eraser = try await NighttimeAirplaneRemover(with: config,
                                                                    numConcurrentRenders: max,
                                                                    callbacks: callbacks,
                                                                    processExistingFiles: false,
                                                                    maxResidentImages: 40, // XXX
                                                                    writeOutputFiles: writeOutputFiles)
                    
                    var upm: UpdatableProgressMonitor?
                    
                    if let _ = eraser.callbacks.updatable {
                        // setup sequence monitor
                        let updatableProgressMonitor =
                          await UpdatableProgressMonitor(frameCount: eraser.imageSequence.filenames.count,
                                                         numConcurrentRenders: max,
                                                         config: eraser.config,
                                                         callbacks: callbacks)
                        upm = updatableProgressMonitor
                        eraser.callbacks.frameStateChangeCallback = { frame, state in
                            Task(priority: .userInitiated) {
                                await updatableProgressMonitor.stateChange(for: frame, to: state)
                            }
                        }
                    }
                    
                    Log.dispatchGroup = await eraser.dispatchGroup.dispatchGroup
                    try await eraser.run()

                    Log.i("done")

                    if let updatableProgressMonitor = upm {
                        await updatableProgressMonitor.dispatchGroup.wait()
                        // simply sleep a small amount? 
                        //try await Task.sleep(nanoseconds: 1_000_000_000)
                        print("processing complete, output is in \(eraser.outputDirname)")
                    }
                } catch {
                    Log.e("\(error)")
                }
                localDispatch.leave()
            }
            localDispatch.wait()
        } else {
            throw ValidationError("need to provide input")
        }
        Log.dispatchGroup.wait()
    }
}

// needs ArgumentParser, so it's here in cli land
// allows the log level to be expressed on the command line as an argument
extension Log.Level: ExpressibleByArgument { }

fileprivate let fileManager = FileManager.default
