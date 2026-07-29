import ArgumentParser
import Foundation
import StarCore
import logging
import StarDecisionTrees
import StarCppBridge
#if canImport(Observation)
import Observation
#endif

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


/*
 todo:

 - redo the initial blob detection, it can miss pretty bright lines of dots

 1. add a layer of processing in the blob detection, that pays attention
    to the difference between the processed frame and its subtraction image.
    starting at the brighest part of a blob, attempt to do blob detection
    for that spot on the processed frame (as compared to the blob, which
    came from the subtration frame).  If we are able to get a bigger blob
    with a lot of bright spots on it, then discard the blob.
    Allow fuck tons of more blobs originally so that we can get dim airplanes
    Should allow for better airplane detection with fewer false positives.
    
 - add three new classification criteria:
 
 1. use the mask created by an outlier group to look at the difference in
    brightness between the pixels in the mask and the pixels outside it
    (need to make some kind of bound for cheking outside the mask)
    return value is the ratio of the average of the brightness of each
 2. for each outlier group, look at the difference in brightness between
    the pixels that are in the group in the frame being processed,
    and within the aligned reference frame we would paint from.
    return value is the brightness of pixels
    within the frame being modified / within the reference frame
 3. within the outlier groups bounding box, return the average brightess
    of all pixels not in the outlier group.

 
 - loading outliers is still painfully slow
 - UI crashes sometimes and brings down the system

 - make render this frame have a keyboard shortcut
 - change how gui frame saver works, sometimes it misses changes
 - have saved frames also render
 
 - try this for GPU, metal sucks:
   https://github.com/philipturner/swift-opencl
 
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


@main
struct StarCli: AsyncParsableCommand {

    @Option(name: [.customShort("l"), .customLong("console-log-level")], help:"""
        The logging level that star will output directly to the terminal.
        """)
    var terminalLogLevel: Log.Level?/* = .info*/

    @Option(name: [.customShort("c"), .customLong("clean-method")], help:"""
        The clean mode to use for this image sequence.
        Defaults to automatic for a new sequence, and to whatever a saved config
        already holds when resuming one.
        """)
    var cleanMethod: CleanMethod?

    @Flag(name: [.customLong("no-horizon")], help:"""
        This video does not contain a horizon (horizon is assumed by default)
        """)
    var noHorizon: Bool = false

    @Flag(name: [.customLong("keep-temp-files")], help:"""
        Do not remove temporary files after processing is completed.
        The saved config.json is kept either way, so a completed run can always be
        resumed with `star star_temp_<sequence>/config.json`; this flag additionally
        keeps the outlier data and the horizon, keypoint and alignment caches, which
        is what makes such a resume pick up where this run left off instead of
        rebuilding them.
        """)
    var keepTempFiles: Bool = false

    @Flag(name: [.customLong("moving-camera")], help:"""
        This video was shot with a moving camera.
        By default star assumes the video was shot on a stationary tripod head.
        """)
    var movingCamera: Bool = false

    @Flag(name: [.customLong("half-res-keypoints")], help:"""
        Detect keypoints on a half size copy of each frame.
        Cuts the peak memory of the keypoint step by around 3.5x (measured
        9921MB -> 2824MB at 42 megapixels) and runs about 4x faster, at the cost
        of finding fewer and slightly less precise keypoints.  May reduce
        alignment quality on some sequences, so compare against a full
        resolution run.  Keypoint files are stored separately per setting.
        """)
    var halfResKeypoints: Bool = false

    @Option(name: [.customLong("merge-streaming-threshold-mb")], help:"""
        When a median merge would need to hold more than this many megabytes of
        source frames at once, stream them from scratch files instead of keeping
        them all in memory.  Applies both to the static earth merge and to building
        each star aligned frame from its warped neighbours.  The output is bit
        identical either way; streaming trades disk io for ram.  Measured at 42
        megapixels: 17 static sources 4354MB resident vs 779MB streaming, 9 aligned
        sources 2178MB vs 728MB.
        Those are per merge in isolation.  End to end, streaming is roughly twice as
        slow at 42 megapixels and saves no peak memory at all, because the peak of a
        run is set by the keypoint phase rather than by any merge — which is why the
        default is 8192 rather than the 2048 that made a 42 megapixel run stream every
        merge.  Lower it if you are memory bound rather than time bound, or if you run
        with half resolution keypoints, which drops the keypoint peak far enough that
        a merge can become the largest thing in the run.
        Set to 0 to always keep every source in memory.
        """)
    var mergeStreamingThresholdMB: Int?

    @Option(name: [.customLong("max-keypoint-ops")], help:"""
        Cap how many keypoint detection ops run at once.
        Independent of the memory estimate: use this to be more conservative than
        the budget math instead of raising the keypoint memory multiplier, which
        also inflates every keypoint op's reservation.
        This is a cap, so it can only lower the limit, never raise it above what
        the memory budget allows.  Omit or 0 for no explicit cap.
        """)
    var maxKeypointOps: Int?

    @Option(name: [.customLong("horizon-reservation-floor-mb")], help:"""
        Least memory, in megabytes, to reserve for one horizon operation.
        A horizon op's cost is mostly fixed rather than per frame size, because the
        detector works at a fixed internal resolution, so a plain multiple of the
        frame under-reserves on small frames: measured in a fresh process, the
        horizon multiplier covered only 57% of what one op needed at 6 megapixels
        and 76% at 12, against 133% at 24 and 175% at 42.  This floor covers the
        small end without inflating the large end.  Default 900, which stops
        binding at about 17 megapixels, where the multiplier overtakes it.
        Set to 0 to use the multiplier alone.
        """)
    var horizonReservationFloorMB: Int?

    @Flag(name: [.customLong("log-op-memory")], help:"""
        Log each operation's actual peak memory against what it reserved.
        Use with --num-concurrent-renders 1 so the process footprint delta is
        attributable to a single operation.  This is how the per-op memory
        multipliers are derived from measurement rather than guessed.
        """)
    var logOpMemory: Bool = false
    
    @Option(name: [.short, .customLong("file-log-level")], help:"""
        If present, star will output a file log at the given level.
        """)
    var fileLogLevel: Log.Level?

    @Option(name: [.short, .customLong("output-path")], help:"""
        The filesystem location under which star will create output dir(s).
        Defaults to creating output dir(s) alongside input sequence dir
        """)
    var outputPath: String?
    
    @Option(name: .shortAndLong, help: """
        Max Number of frames to process at once.
        May need to be reduced to a lower value if to consume less ram on some machines.
        Defaults to three quarters of the cpu count for a new sequence, and to whatever
        a saved config already holds when resuming one.
        """)
    var numConcurrentRenders: UInt?

    @Option(name: .shortAndLong, help: "Detection Types")
    var detectionType: DetectionType?

    @Option(name: .shortAndLong, help: """
        When set, outlier groups closer to the bottom of the screen than this are ignored.
        This can be helpful to reduce the number of outlier groups on the ground.
        """)
    var ignoreLowerPixels: Int?

    @Flag(name: [.customShort("w"), .customLong("write-outlier-group-files")],
          help:"Write individual outlier group image files")
    var shouldWriteOutlierGroupFiles = false

    @Option(name: [.customShort("L"), .customLong("last-frame")], help:"""
        Stop after this frame, leaving the rest of the sequence unprocessed.
        A zero based frame index, counted the way the logs count frames, and
        inclusive: --last-frame 9 processes the first ten frames.
        Frames past it are still read and aligned where a processed frame needs
        them as a neighbour, but no output is written for them.
        A limit on this run only: it is not saved into the config, so resuming
        without the flag processes the whole sequence.  Pair it with
        --keep-temp-files to keep the outlier data and the horizon, keypoint and
        alignment caches this run built, all of which are deleted otherwise.
        """)
    var lastFrameIndex: Int? = nil

    @Flag(name: [.customShort("W"), .customLong("write-outlier-classification-values")],
          help:"Write individual outlier group classification values")
    var shouldWriteOutlierClassificationValues = false

    @Flag(name: .shortAndLong, help:"Show version number")
    var version = false

    @Flag(name: .shortAndLong,
          inversion: .prefixedNo,
          help:"""
        Only write out outlier data, not images.
        Each frame detects its outliers and writes their remove reasons, plus the
        classification values if -W is given, and then stops before writing any image.
        Useful for gathering classifier training data from a sequence you have no
        intention of rendering.  Note that the alignment and merge still run, since the
        outliers are found by subtracting the merged frame — what this saves is the
        airplane replacement and every image write, not the expensive part.
        Only meaningful with a clean method that uses outliers, so --clean-method
        selective or automatic:true; under plain automatic there are no outliers to write
        and a run produces nothing at all.
        Saved into the config like every other flag here, so a resume that does not repeat
        it still skips them; --no-skip-output-files turns rendering back on.
        """)
    var skipOutputFiles: Bool?

    @Argument(help: """
        Image sequence dirname to process. 
        Should include a sequence of 8 or 16 bit image files, sortable by name.
        """)
    var imageSequenceDirname: String?

    @Argument(help: """
        Final destination for output files
        defaults to <image-sequence-dirname>-star-version if not set
        """)
    var finalOutputDirname: String? = nil

    /// The flags above in the single form both input paths apply — see `ConfigOverrides`
    /// for why a `@Flag` becomes `true` or nil here, and never `false`.
    var configOverrides: ConfigOverrides {
        ConfigOverrides(
          cleanMethod: cleanMethod,
          detectionType: detectionType,
          finalOutputDir: finalOutputDirname,
          writeOutlierGroupFiles: shouldWriteOutlierGroupFiles ? true : nil,
          writeOutlierClassificationValues: shouldWriteOutlierClassificationValues ? true : nil,
          // -s is the tri-state one: nil when neither it nor its --no- form was typed
          writeOutputFiles: skipOutputFiles.map { !$0 },
          horizonDetectionEnabled: noHorizon ? false : nil,
          tripodHeadWasMoving: movingCamera ? true : nil,
          alignmentHalfResolutionKeypoints: halfResKeypoints ? true : nil,
          mergeStreamingThresholdMB: mergeStreamingThresholdMB,
          maxConcurrentKeypointOps: maxKeypointOps,
          horizonReservationFloorMB: horizonReservationFloorMB,
          numberOfFramesToProcessConcurrently: numConcurrentRenders.map { Int($0) },
          ignoreLowerPixels: ignoreLowerPixels
        )
    }

    func validate() throws {
        // A negative last frame selects nothing at all.  FrameGraphBuilder reports that
        // and exits cleanly, but by then it has loaded the whole sequence, so say it
        // here as the usage error it is.
        if let lastFrameIndex, lastFrameIndex < 0 {
            throw ValidationError(
              "--last-frame must be a frame index of 0 or more, not \(lastFrameIndex)"
            )
        }
    }

    mutating func run() async throws {

        var configManager: ConfigManager = await ConfigManager()

        // process globals rather than config fields, so they are set the same way on
        // both input paths, before either of them runs
        if let numConcurrentRenders {
            TaskRunner.maxConcurrentTasks = numConcurrentRenders
        }
        logOperationMemory = logOpMemory

        var callbacks = Callbacks()

        // gui has to do this too
        await StarCore.currentClassifier.set(for: .all) {
            OutlierGroupForestClassifier_2436760d()
        }
        await StarCore.currentClassifier.set(for: .isolated) {
            OutlierGroupForestClassifier_f9f52500()
        }

        if version {
            print("""
                  Starry Timelapse Airplane Remover (star) version \(Config.latestVersion)
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

                do {
                    configManager =
                      try await ConfigManager(configFilename: inputImageSequenceDirname)
                    var config = await configManager.config()
                    // the saved config supplies the defaults, the command line overrides
                    // them — the same overrides the image sequence path below applies
                    configOverrides.apply(to: &config)
                    // update() saves, as it always has here, so an override is written
                    // back into the config file and a later resume without the flag
                    // keeps it
                    await configManager.update(config)
                    // overwrite global constants constant
                    // not really thread safe,
                    // but we only do it here before starting any other threads.
                    await constants.set(detectionType: config.detectionType)

                } catch {
                    print("\(error)")
                }

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
                      FileManager.default.currentDirectoryPath + "/" + 
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

                // only what the sequence itself determines goes in here; every flag
                // arrives through configOverrides below, so that the config file path
                // above applies the identical set
                var config = Config(
                  outputPath: _outputPath,
                  imageSequenceName: inputImageSequenceName,
                  imageSequencePath: inputImageSequencePath,
                  writeOutlierGroupFiles: false,
                  writeFramePreviewFiles: false,
                  writeFrameProcessedPreviewFiles: false,
                  writeFrameThumbnailFiles: false
                )

                configOverrides.apply(to: &config)

                // ConfigManager holds a copy of this struct, so all mutations
                // to config must happen before it is constructed here
                let configFilename = "config.json"
                
                configManager = await ConfigManager(
                  configFilename: configFilename,
                  config: config
                )
                
                await constants.set(detectionType: config.detectionType)

                Log.nameSuffix = inputImageSequenceName
                // no name suffix on json config path
            }

            Log.name = "star-log"

            if let terminalLogLevel = terminalLogLevel {
                // use console logging
                Log.add(handler: ConsoleLogHandler(at: terminalLogLevel),
                        for: .console)
            } else {
                // enable updatable logging when not doing console logging
                callbacks.updatable = UpdatableLog()

                if let updatable = callbacks.updatable {
                    Log.add(
                      handler: UpdatableLogHandler(updatable),
                      for: .console
                    )
                    let name = inputImageSequenceName
                    let path = inputImageSequencePath
                    let message = "star v\(Config.latestVersion) is processing images from sequence in \(path)/\(name)"
                    Task {
                        await updatable.log(
                          name: "star",
                          message: message,
                          value: -1
                        )
                    }
                }
            }

            if let fileLogLevel = fileLogLevel {
                Log.i("enabling file logging")
                do {
                    Log.add(handler: try FileLogHandler(at: fileLogLevel),
                            for: .file)
                } catch {
                    Log.e("\(error)")
                }
            }
            
            setupKHTLogging()

            // SIGKILL doesn't exist in the Windows C runtime (which only
            // exposes SIGABRT/SIGFPE/SIGILL/SIGINT/SIGSEGV/SIGTERM), so
            // gate this for non-Windows. Note that on POSIX this is also
            // a no-op — SIGKILL is uncatchable, so signal() returns
            // SIG_ERR and the closure is never invoked.
            #if !os(Windows)
            signal(SIGKILL) { foo in
                print("caught SIGKILL \(foo)")
            }
            #endif
            
            Log.i("looking for files to processes in \(inputImageSequenceDirname)")
            do {
                
                let processor = try await Processor(
                  with: configManager,
                  callbacks: callbacks,
                  maxResidentImages: 40 // XXX
                )

                if let _ = callbacks.updatable {
                    // setup sequence monitor
                    let updatableProgressMonitor =
                      UpdatableProgressMonitor(
                        frameCount: await processor.frameCount,
                        numConcurrentRenders: 30, // XXX use num cpus?
                        config: await configManager.config(),
                        callbacks: callbacks
                      )

                    Task {
                        for await operations in streamFrameChanges() {
                            await updatableProgressMonitor.operationsChange(operations)
                        }
                    }
                    
                    callbacks.frameStateChangeCallback = { frame, state in
                        // XXX make sure to wait for this
                        print("frame \(frame) state change to \(state)")
                        Task(priority: .userInitiated) {
                            await updatableProgressMonitor.stateChange(for: frame, to: state)
                        }
                    }
                    callbacks.exisingFrameStateChangeCallback = { frameIndex in
                        Task(priority: .userInitiated) {
                            await updatableProgressMonitor.notProcesssingFrame(at: frameIndex)
                        }
                    }
                }
                
                // --last-frame is an argument to this one call rather than a Config
                // field, which is both why it reaches whichever input path ran above —
                // there is only one call — and why it does not persist into the saved
                // config.json the way an override would.
                try await processor.process(endIndex: lastFrameIndex)

                Log.i("done")

                let config = await configManager.config() 
                if let updatable = callbacks.updatable {
                    let message = "star processing was successful, output sequence is in \(config.outputSequenceDirname)"
                    Task {
                        await updatable.log(
                          name: "star",
                          message: message,
                          value: 1000
                        )
                    }
                }

                if !self.keepTempFiles {
                    // rm temp unless told not to, but leave the saved config behind:
                    // it is the only thing under there that a later
                    // `star <temp>/config.json` needs, and deleting it made a run that
                    // completed normally the one kind of run that could not be resumed.
                    try? removeTempFiles(at: config.tempOutputPath,
                                         sparing: config.jsonPath(
                                           named: await configManager.jsonFilename()
                                         ))
                }
                
            } catch {
                Log.e("\(error)")
            }

        } else {
            throw ValidationError("need to provide input")
        }
        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging() // XXX broken on swift6 :(
    }
}

// needs ArgumentParser, so it's here in cli land
// allows the log level to be expressed on the command line as an argument
extension Log.Level: @retroactive ExpressibleByArgument { }

extension DetectionType: @retroactive ExpressibleByArgument { }

extension CleanMethod: ExpressibleByArgument {
    public init?(argument: String) {
        let lowercased = argument.lowercased()

        switch lowercased {
        case "selective":
            self = .selective

        case "automatic":
            // default automatic behavior if no flag is provided
            self = .automatic(false)

        case "automatic:true",
             "automatic:yes",
             "automatic:1":
            self = .automatic(true)

        case "automatic:false",
             "automatic:no",
             "automatic:0":
            self = .automatic(false)

        default:
            return nil
        }
    }

    public static var allValueStrings: [String] {
        [
            "selective",
            "automatic",
            "automatic:true",
            "automatic:false"
        ]
    }
}

func streamFrameChanges() -> AsyncStream<[OperationType: [OperationState: UInt]]> {
    AsyncStream { continuation in
        
        Task { @MainActor in
            registerTracking(continuation: continuation)
        }
    }
}

@MainActor
private func registerTracking(
    continuation: AsyncStream<[OperationType: [OperationState: UInt]]>.Continuation
) {
    _ = withObservationTracking {
        continuation.yield(
            frameGraphViewModel.operations
        )
    } onChange: {
        Task { @MainActor in
            registerTracking(continuation: continuation)
        }
    }
}

/// Remove a finished run's temp working files, keeping `sparedPath`.
///
/// Everything under the temp dir is regenerable except the saved config, which is what
/// `star <temp>/config.json` resumes from — so that one file outlives the working files
/// it was written alongside and the emptied dir stays behind to hold it.
///
/// `sparedPath` need not be under `path` at all: stard names an absolute session dir
/// elsewhere, and for that the whole temp dir goes, as it always did.
func removeTempFiles(at path: String, sparing sparedPath: String) throws {
    let fileManager = FileManager.default
    let tempURL = URL(fileURLWithPath: path)

    guard fileManager.fileExists(atPath: tempURL.path) else {
        print("Directory does not exist.")
        return
    }

    // both sides through URL so a relative temp path and the resolved config path — which
    // is relative whenever the resume argument was — compare as the same absolute path
    let spared = URL(fileURLWithPath: sparedPath).standardizedFileURL.path

    var sparedAnything = false
    for child in try fileManager.contentsOfDirectory(at: tempURL,
                                                    includingPropertiesForKeys: nil)
    {
        if child.standardizedFileURL.path == spared {
            sparedAnything = true
            continue
        }
        try fileManager.removeItem(at: child)
    }

    if !sparedAnything {
        try fileManager.removeItem(at: tempURL)
    }
}
