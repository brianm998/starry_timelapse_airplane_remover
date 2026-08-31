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


/// The real entry point, ahead of `StarCli` itself.
///
/// `--language` has to be applied before `swift-argument-parser` gets the command line at all.
/// The parser builds its help by instantiating `StarCli`, which evaluates every
/// `localized(...)` in a `help:` argument as it goes — so a language read from the *parsed*
/// value would arrive one step too late and `star --language ja --help` would print English.
/// Scanning raw argv here costs nothing and gets the ordering right.
@main
enum StarMain {
    static func main() async {
        StarLocalization.applyEarlyLanguageSelection()
        await StarCli.main()
    }
}

struct StarCli: AsyncParsableCommand {

    @Option(name: [.customShort("l"), .customLong("console-log-level")], help: ArgumentHelp(localized("cli.help.terminal_log_level")))
    var terminalLogLevel: Log.Level?/* = .info*/

    @Option(name: [.customShort("c"), .customLong("clean-method")], help: ArgumentHelp(localized("cli.help.clean_method")))
    var cleanMethod: CleanMethod?

    @Flag(name: [.customLong("no-horizon")], help: ArgumentHelp(localized("cli.help.no_horizon")))
    var noHorizon: Bool = false

    @Flag(name: [.customLong("keep-temp-files")], help: ArgumentHelp(localized("cli.help.keep_temp_files")))
    var keepTempFiles: Bool = false

    @Flag(name: [.customLong("moving-camera")], help: ArgumentHelp(localized("cli.help.moving_camera")))
    var movingCamera: Bool = false

    @Option(name: [.customLong("keypoint-divisor")], help: ArgumentHelp(localized("cli.help.keypoint_divisor")))
    var keypointDivisor: Double?

    @Option(name: [.customLong("merge-streaming-threshold-mb")], help: ArgumentHelp(localized("cli.help.merge_streaming_threshold_mb")))
    var mergeStreamingThresholdMB: Int?

    @Option(name: [.customLong("max-keypoint-ops")], help: ArgumentHelp(localized("cli.help.max_keypoint_ops")))
    var maxKeypointOps: Int?

    @Option(name: [.customLong("horizon-reservation-floor-mb")], help: ArgumentHelp(localized("cli.help.horizon_reservation_floor_mb")))
    var horizonReservationFloorMB: Int?

    @Flag(name: [.customLong("log-op-memory")], help: ArgumentHelp(localized("cli.help.log_op_memory")))
    var logOpMemory: Bool = false
    
    @Option(name: [.short, .customLong("file-log-level")], help: ArgumentHelp(localized("cli.help.file_log_level")))
    var fileLogLevel: Log.Level?

    @Option(name: [.short, .customLong("output-path")], help: ArgumentHelp(localized("cli.help.output_path")))
    var outputPath: String?
    
    @Option(name: .shortAndLong, help: ArgumentHelp(localized("cli.help.num_concurrent_renders")))
    var numConcurrentRenders: UInt?

    @Option(name: .shortAndLong, help: ArgumentHelp(localized("cli.help.detection_type")))
    var detectionType: DetectionType?

    @Option(name: .shortAndLong, help: ArgumentHelp(localized("cli.help.ignore_lower_pixels")))
    var ignoreLowerPixels: Int?

    @Flag(name: [.customShort("w"), .customLong("write-outlier-group-files")],
          help: ArgumentHelp(localized("cli.help.should_write_outlier_group_files")))
    var shouldWriteOutlierGroupFiles = false

    @Option(name: [.customShort("L"), .customLong("last-frame")], help: ArgumentHelp(localized("cli.help.last_frame_index")))
    var lastFrameIndex: Int? = nil

    @Flag(name: [.customShort("W"), .customLong("write-outlier-classification-values")],
          help: ArgumentHelp(localized("cli.help.should_write_outlier_classification_values")))
    var shouldWriteOutlierClassificationValues = false

    @Flag(name: .shortAndLong, help: ArgumentHelp(localized("cli.help.version")))
    var version = false

    /// Declared so it appears in `--help` and so an unknown `--language` is still a parse
    /// error rather than being silently swallowed. The value is *not* read from here: it has
    /// already been applied by `StarMain` before the parser ran — see the comment there.
    @Option(name: [.customLong("language")], help: ArgumentHelp(localized("cli.help.language")))
    var language: String?

    @Flag(name: [.customLong("list-languages")], help: ArgumentHelp(localized("cli.help.list_languages")))
    var listLanguages = false

    @Flag(name: .shortAndLong,
          inversion: .prefixedNo,
          help: ArgumentHelp(localized("cli.help.skip_output_files")))
    var skipOutputFiles: Bool?

    @Argument(help: ArgumentHelp(localized("cli.help.image_sequence_dirname")))
    var imageSequenceDirname: String?

    @Argument(help: ArgumentHelp(localized("cli.help.final_output_dirname")))
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
          alignmentKeypointDetectionDivisor: keypointDivisor,
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
        // Config clamps a divisor below 1 to full resolution rather than honouring it,
        // and the C++ would silently do the same, so a typo like 0.5 would run at full
        // size and look like the flag did nothing.  Say so instead.
        if let keypointDivisor, keypointDivisor < 1 {
            throw ValidationError(
              "--keypoint-divisor divides the frame size, so it must be 1 or more, not "
              + "\(keypointDivisor). Use 2 for half size, 1.5 for two thirds."
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

        // Before anything else that could crash. A fatal signal during argument handling or
        // sequence resolution is exactly as worth reporting as one during processing, and
        // arming this early costs nothing. The log path is not known yet — it is handed over
        // below, once the file log handler exists.
        StarCrashHandler.install()

        // Ctrl-C, `kill`, or a closed terminal now stop the run in an orderly way: cancel
        // outstanding work, print how to resume, clear the run marker, and drain the log queue
        // — rather than dying instantly, losing whatever the gremlin had queued, and leaving a
        // marker behind for the next launch to report as a crash.
        StarShutdown.install(clientName: "star")

        // gui has to do this too
        await StarCore.currentClassifier.set(for: .all) {
            OutlierGroupForestClassifier_2436760d()
        }
        await StarCore.currentClassifier.set(for: .isolated) {
            OutlierGroupForestClassifier_f9f52500()
        }

        if listLanguages {
            print(StarLocalization.shared.languageListing())
            return
        }

        if version {
            print(localized("cli.version", Config.latestVersion))
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
                    // update()'s write is async and coalesced, and the cli can
                    // reach its exit before one lands, so make this one wait.
                    await configManager.flush()
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

            // Read and print any previous run's crash report *before* the block below,
            // because without --terminal-log-level that block installs `UpdatableLog`, which
            // owns the terminal and redraws with cursor-relative escapes.  A multi-line
            // report printed after that gets scribbled over.  The `Log.w` counterpart is
            // deferred to just after the handlers exist, so the report also lands in this
            // run's log file — reporting it in one place would mean losing either the
            // terminal copy or the logged one.
            let abandonedRuns = await RunMarkerStore.shared.abandonedRuns()
            printReports(for: abandonedRuns)

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

            // Kept so the run marker can name it: when a run is killed, the single most
            // useful thing a crash report can tell the user is where its log went.
            var fileLogPath: String?
            if let fileLogLevel = fileLogLevel {
                Log.i("enabling file logging")
                do {
                    let fileLogHandler = try FileLogHandler(at: fileLogLevel)
                    fileLogPath = fileLogHandler.full_log_path
                    Log.add(handler: fileLogHandler, for: .file)
                    // So a fatal signal appends a line saying so to this very file. Without
                    // it, a log a user sends in just stops mid-sentence — which is precisely
                    // the report that started all of this.
                    StarCrashHandler.setLogPath(fileLogPath)
                } catch {
                    Log.e("\(error)")
                }
            }

            setupKHTLogging()

            // Put machine-level warnings — memory pressure, a footprint past budget —
            // where the user can see them.  Until this existed the OS's memory-pressure
            // notification only throttled the admission gate, so a run walked into an
            // out-of-memory kill behind a normal-looking progress display.
            //
            // Note this must happen before Processor is constructed: Processor copies
            // `callbacks` at init and hands that copy to every frame, so anything assigned
            // to `callbacks` afterwards never reaches them.
            let warningLog = callbacks.updatable
            callbacks.warningCallback = { warning in
                if let warningLog {
                    Task {
                        await warningLog.log(
                          name: "warning-\(warning.kind.rawValue)",
                          message: "⚠️  \(warning.oneLineDescription)",
                          // Above the "star is processing..." header at -1, because a
                          // warning the user scrolls past is a warning wasted.
                          value: -2
                        )
                    }
                } else {
                    // Straight to fd 2, not `print`. stdout is block-buffered when it is not a
                    // terminal, and these warnings are precisely the ones issued shortly
                    // before the process may be killed — by the OOM killer, or by a second
                    // interrupt taking the `_exit` path, neither of which flushes stdio. A
                    // warning that only exists in a buffer is not a warning. Observed: a
                    // low-disk warning vanished entirely from a redirected run that was later
                    // signalled.
                    FileHandle.standardError.write(
                      Data("⚠️  \(warning.oneLineDescription)\n".utf8))
                }
            }
            await callbacks.installWarningHandler()

            // Count frames reaching their terminal state, so a crash report can say how far
            // the run got.  Assigned here rather than in the `updatable` branch below for
            // the copy-semantics reason above.
            callbacks.frameStateChangeCallback = { frame, state in
                Task {
                    await RunMarkerStore.shared.note(
                      phase: "\(state)",
                      frameCompleted: state == .complete ? frame.frameIndex : nil
                    )
                }
            }

            // The logged half of the report above, now that there are handlers to receive it.
            for marker in abandonedRuns {
                Log.w("previous run did not finish: \(marker.summary)")
            }
            await RunMarkerStore.shared.clearAbandoned()

            await RunMarkerStore.shared.begin(
              client: "star",
              sequenceName: inputImageSequenceName,
              sequencePath: inputImageSequencePath,
              logPath: fileLogPath
            )

            // (Signal handling used to be attempted here with signal(SIGKILL), which could
            // never fire — SIGKILL is uncatchable, so signal() just returns SIG_ERR. What it
            // was reaching for is now real, and installed near the top of run(): fatal signals
            // via StarCrashHandler, interruptions via StarShutdown. An out-of-memory SIGKILL
            // is still uncatchable, and is covered after the fact by RunMarker.)

            Log.i("looking for files to processes in \(inputImageSequenceDirname)")

            // How the run ended, decided here and acted on after the cleanup below, so that a
            // failure still gets its marker cleared and its logs drained before the process
            // exits non-zero.
            var thrownFailure: Error?
            var frameErrors: [String] = []

            do {
                
                let processor = try await Processor(
                  with: configManager,
                  callbacks: callbacks,
                  maxResidentImages: 40 // XXX
                )

                // Processor.init is what calls Config.set(imageInfo:), so this is the first
                // point at which the run's shape is known.  Also the resume path, so a
                // crash report can print a command the user can run.
                await RunMarkerStore.shared.update(
                  frameCount: await processor.frameCount,
                  resumeConfigPath: await configManager.config().jsonPath(
                    named: await configManager.jsonFilename()
                  ),
                  imageWidth: await configManager.config().imageWidth,
                  imageHeight: await configManager.config().imageHeight,
                  imageBytesPerPixel: await configManager.config().imageBytesPerPixel
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
                    
                    // Chain rather than replace.  This assignment currently has no effect —
                    // Processor already copied `callbacks` at init — but if that is ever
                    // fixed, overwriting the field here would silently take the run marker's
                    // progress tracking with it.
                    let previousStateChange = callbacks.frameStateChangeCallback
                    callbacks.frameStateChangeCallback = { frame, state in
                        previousStateChange?(frame, state)
                        // XXX make sure to wait for this
                        print(localized("cli.frame_state_change", frame, state))
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
                frameErrors = try await processor.process(endIndex: lastFrameIndex)

                Log.i("done")

                let config = await configManager.config()
                if frameErrors.isEmpty, let updatable = callbacks.updatable {
                    let message = "star processing was successful, output sequence is in \(config.outputSequenceDirname)"
                    Task {
                        await updatable.log(
                          name: "star",
                          message: message,
                          value: 1000
                        )
                    }
                }

                // A run with frame errors keeps its temp directory whatever the flag says.
                // Deleting it is only safe for a run that produced everything it was going
                // to: the temp dir is what `star <temp>/config.json` resumes from, and
                // removing it after a partial failure destroys the one thing that would let
                // the user finish the frames that did not make it.
                if !self.keepTempFiles, frameErrors.isEmpty {
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
                thrownFailure = error
            }

            // Reached whether the run succeeded or threw: a failure that got as far as being
            // caught and logged is not a crash, and leaving the marker behind would have the
            // next launch report it as one.
            await RunMarkerStore.shared.finish()

            // Say it on stderr, not only through Log. Without a --console-log-level there is
            // no console handler at all, so a run whose only record of failure was a Log.e
            // could finish with the progress display still showing and nothing to say it had
            // gone wrong.
            if let thrownFailure {
                FileHandle.standardError.write(Data("\nstar: failed: \(thrownFailure)\n".utf8))
            } else if !frameErrors.isEmpty {
                let config = await configManager.config()
                let resumePath = config.jsonPath(named: await configManager.jsonFilename())
                FileHandle.standardError.write(
                  Data(frameErrorSummary(frameErrors, resumePath: resumePath).utf8))
            }

            await TaskWaiter.shared.finish()
            await logging.gremlin.finishLogging() // XXX broken on swift6 :(

            // Exit non-zero so anything scripting star can tell the difference. `ExitCode`
            // rather than rethrowing the original error: ArgumentParser prints what it is
            // given, and this one has already been reported above and in the log — throwing
            // it again would say the same thing twice in two different formats.
            if thrownFailure != nil || !frameErrors.isEmpty {
                throw ExitCode.failure
            }
            return

        } else {
            throw ValidationError("need to provide input")
        }
    }
}

/// What a run that finished with per-frame errors tells the user.
///
/// Written to stderr rather than through `Log`: without `--console-log-level` there is no
/// console handler at all, so a run whose only record of failure was a `Log.e` would end with
/// the progress display still on screen and nothing to say anything had gone wrong.
///
/// Truncated, because a sequence where every frame failed would otherwise print hundreds of
/// near-identical lines and push the one actionable thing — the resume command — off the top
/// of the terminal.
func frameErrorSummary(_ errors: [String], resumePath: String) -> String {
    let shown = 10
    var message = "\n" + (errors.count == 1
                            ? localized("cli.errors.finished_one")
                            : localized("cli.errors.finished_many", errors.count)) + "\n"
    for error in errors.prefix(shown) { message += "  \(error)\n" }
    if errors.count > shown {
        message += "  " + localized("cli.errors.and_more", errors.count - shown) + "\n"
    }
    message += localized("cli.errors.resume_header") + "\n"
    message += "  star \(resumePath)\n"
    return message
}

/// Print the crash report for each run that ended without clearing its marker.
///
/// Printed rather than only logged: the whole point is that the run this is about produced no
/// error message of its own, so a user who has just been dumped back at a shell prompt with
/// nothing to go on needs to see it without being told to go looking for a log.
func printReports(for markers: [RunMarker]) {
    guard !markers.isEmpty else { return }
    for marker in markers {
        print("")
        print("────────────────────────────────────────────────────────────────────────")
        print(marker.report)
        print("────────────────────────────────────────────────────────────────────────")
        print("")
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
        print(localized("cli.directory_does_not_exist"))
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
