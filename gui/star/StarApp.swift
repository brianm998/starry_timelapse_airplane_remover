//
//  starApp.swift
//  star
//
//  Created by Brian Martin on 2/1/23.
//

import SwiftUI
import StarCore
import logging
import StarDecisionTrees
import StarCppBridge

/*

 * slider to allow merging frame with black background to see outliers easier and still see frame
 - allow selections that are not rectangular
 * allow UI to start outlier detection for a single frame
 * make lower views less cluttered
 * add render this frame button
 - add progress view for flimstrip, and edit view
 * add frame state to edit view
 
 UI Improvements:
  * scroll back and forth through frames
  * don't finish frames until some number later
  * improve speed when still processing files
  - overlier hover to give paint reason and size
  * feature to split outlier groups apart
  - add ability to have selection work for just part of outlier group, or all like now
  - have streak detection take notice of user choices before processing further frames

  - add meteor detection phase, which the backend will use to accentuate this outlier

  * fix bug where zooming and selection gestures correspond
  - allow dark/light themes
  * the filmstrip doesn't update very quickly on its own
  * make it overwrite existing output files
  * fix final queue usage from UI so it doesn't crash by trying to save the same frame twice

  - allow showing changed frames too
  
  * try a play button for playing a preview
  * of both rendered and original

  * outlier groups get wrong when scrolling
    - kindof fixed it

  - let shift + forward and back move 10-100 spaces instead of one
  * shortcut to go to the beginning and to the end of the sequence
  * play button with frame rate slider

  - rename previews/scrub and add and preview size to config
  * add config option to write out previews of both original and modified images to file
  * upon load, use the previews if they exist

  * add a button that calls frame.outlierGroups() on all frames to load their outliers

  * have filmstrip show outlier group load status somehow
  
  NEW UI:

  * have a render all button
  - add filter options by frame state to constrain the filmstrip
  - make filmstrip sizeable by dragging the top of it
  * make it possible to play the video based upon previews
    * could be faster
  
  - add status flags for frames
    * don't have outliers
    * loading outliers
    * have outliers
    - saving

    * show progress in saving in UI


  * add slider for outlier opacity

  - add overlay grid which shows color based upon what kind of outliers are inside:
    - blank for nothing
    - green for only no paint
    - red for only paint
    - purple for both
    - configurable number of boxes on each axis

  * add frame number to all views
  * show number of outliers in each frame, of each type
  * feature to allow splitting up outliers that include both cloud and airplane
  - toggle to make outliers flash (either kind)
  - function to allow render of all frames that are not present and also those that have changed
  - add feature to fuzz out some outliers, such as light leak from airplanes into clouds
    without this, ghost airplanes are still seen, the bright parts of the streak are gone,
    but a halo around still persists.  XXX somehow detect this beforehand? XXX

  * refactor the view model class so that it doesn't crash when closed when processing 
    problem now is that we re-use the same view model class, need to create another properly

  - orange unknown outlier groups not clickable directly (but are clickable on arrows)
    check to see if selection works or not

    NEEDED for decent GUI release:

    * processing X more frames doesn't update during processing
    * processed previews don't load immediately after processing (should stay in ram)
    * add left panel updates on frame status (similar to cli)
    * on restart after not fully completing processing, finished files are re-done :(
    - more hand holding for setting ignore bar and starting processing
      - detect frame state, see when to tell user about ignore area
      - detect if all frames are processed or not, and ask the user startup to process or not
    * frames get set to user modified when they haven't been 
    - ui jumps when waiting to save frames show up
    - don't try to load outliers when switching to a frame in processing mode
    - don't try to save frame when switching from a frame in processing mode
    - better status on filmstrip, with helper text on hover
    - add 'are you sure' popup when closing when processing
    - add a stop processing button (cancel the processing task)
    - render frame button is sometimes disabled when it shouldn't be
    * frames end up waiting for interframe processing too long, and pile up
    - load all outliers on unprocessed frame starts processing when there are no outliers :(
    * memory leaks lead to crash on processing long sequences
    - fix bug where chevron buttons don't always work

  Next steps for custom blob gui:

    * convert all anonomous process methods to named methods or new processing enum cases
    * create new window UI that can read the list of steps and show it to the user
    * move process(BlobFunctionType) to args format like others
    * move borderBrignessLessThan to args format
    * make GUIBlobProcessor, which allows 
    * allow seeing the settings being used at each step
    * allow creating a custom set of steps starting with an existing one
    - allow keeping track of how a frame was processed for later
    - allow changing the order of steps
    - allow adding new steps
    - allow deleting steps
    * need to have helper text for what the values do
    * find way to get processing methods into json and back
    * allow saving and current state to json
    * allow reading saved json when starting up custom processor 
    - allow switching from one custom back to a default
    - allow starting over with new custom processing steps (delete and copy exisiting set)
    - make blob window open when switching to custom processing and there isn't any yet

  Blobber improvements;
    - process brighter pixels through the set of steps first, without dim ones,
      then do one or more dimmer passes later
    * use a variable min contrast, which changes as the blob expands.
      have a beginning min contrast, which linearly contracts to a final min contrast
      over a given blob size
    
 */

@main
struct StarApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    public static let outlierGroupTableWindowName = "outlierGroupTableWindow"
    public static let blobProcessingStepsWindowName = "blobProcessingStepsWindow"
    public static let debugWindowName = "debugWindow"
    public static let mainWindowName = "mainWindow"
    public static let alignmentWindowName = "alignmentWindowName"

    let viewModel = ViewModel()

    init() {
        // maybe move this elsewhere
        Task {
            await StarCore.currentClassifier.set(for: .all) {
                OutlierGroupForestClassifier_2436760d()
            }
            await StarCore.currentClassifier.set(for: .isolated) {
                OutlierGroupForestClassifier_f9f52500()
            }
        }

        // sets the prefix for log filenames
        Log.name = "Star-logs"

        // XXX make this for debug builds only
        #if DEBUG
        Log.add(handler: ConsoleLogHandler(at: .debug), for: .console)
        #endif

        // Always on, before anything else can go wrong. A release gui used to produce no
        // record of itself at all — file logging is off by default and the console handler
        // above is debug-only — so an app that died left the user with nothing to send and
        // nothing to read. Separate from the user's own file log, which still works as before.
        let diagnosticLogPath = DiagnosticLog.enable()

        Log.i("Starting Up")

        // Synchronously, before the Task below and before any window exists: a crash during
        // startup is still a crash, and the gui is where an unreported one hurts most —
        // there is no terminal it could have left a message in.
        // Pointed at the diagnostic log, so a fatal signal writes its final line into the
        // file the user will actually be asked for.
        StarCrashHandler.install(logPath: diagnosticLogPath)

        // SIGTERM reaches a gui app too — `killall Star`, or a force-quit escalating — and
        // AppKit does not turn it into applicationWillTerminate, so without this the marker
        // survives and the next launch calls it a crash. Quiet, because the gui's stderr goes
        // to the system log rather than anywhere a user reads: clearing the marker is the
        // whole point here, not the message.
        StarShutdown.install(clientName: "Star", quiet: true)

        let viewModel = self.viewModel
        Task {
            // Machine-level warnings reach the user through the same path as a previous
            // run's crash report — `RunMarker.asWarning` — so there is one handler and one
            // piece of UI rather than two of each.
            var callbacks = Callbacks()
            callbacks.warningCallback = { warning in
                Task { @MainActor in viewModel.report(warning: warning) }
            }
            await callbacks.installWarningHandler()

            // A run that never cleared its marker was killed.  The gui is where this matters
            // most: it has no terminal to have left a message in, and file logging is off by
            // default, so before this a user whose app was killed mid-run had nothing at all.
            for marker in await RunMarkerStore.shared.abandonedRuns() {
                Log.w("previous run did not finish: \(marker.report)")
                await MainActor.run { viewModel.report(warning: marker.asWarning) }
            }
            await RunMarkerStore.shared.clearAbandoned()

            await RunMarkerStore.shared.begin(client: "Star", logPath: diagnosticLogPath)
        }
    }

    func enableGUILogs() {
        Log.add(handler: GUILogHandler(at: loggingViewModel.level,
                                       with: loggingViewModel), for: .gui)
    }

    func enableFileLogs() {
        if loggingViewModel.fileLogEnabled {
            do {
                Log.add(handler: try FileLogHandler(at: loggingViewModel.fileLogLevel),
                        for: .file)
            } catch {
                Log.e("cannot add file log handler: \(error)")
            }
        } else {
            Log.removeHandler(for: .file)
        }
        // Deliberately does not touch the crash handler's log path. That points at the
        // always-on diagnostic log, which is the file a crash report should name — routing it
        // here instead would mean the crash line landed in whichever log the user happened to
        // have switched on, or in no log at all.
    }
    
    let loggingViewModel = LoggingViewModel()
    
    var body: some Scene {
        WindowGroup(id: StarApp.blobProcessingStepsWindowName) {
            BlobProcessingView()
              .environment(viewModel)
              .starLanguage(viewModel.languageCode)
        }

        WindowGroup(id: StarApp.alignmentWindowName) {
            AlignmentWindowView()
              .environment(viewModel)
              .starLanguage(viewModel.languageCode)
        }

        WindowGroup(id: StarApp.outlierGroupTableWindowName) {
            OutlierWindowView()
              .environment(viewModel)
              .starLanguage(viewModel.languageCode)
        }

        WindowGroup(id: StarApp.debugWindowName) {
            DebugView()
              .environment(viewModel)
              .environment(loggingViewModel)
              .starLanguage(viewModel.languageCode)
        }

        WindowGroup(id: StarApp.mainWindowName) {
            ContentView()
              .environment(viewModel)
              .environment(loggingViewModel)
              .environment(StarCore.frameGraphViewModel)
              .background(MainWindowAccessor { window in
                  appDelegate.viewModel = viewModel
                  window.delegate = appDelegate
              })
              .onAppear {
                  enableGUILogs()
                  setupKHTLogging()
                  appDelegate.viewModel = viewModel
              }
              .onChange(of: loggingViewModel.level) {
                  enableGUILogs()
              }
              .onChange(of: loggingViewModel.fileLogEnabled) {
                  enableFileLogs()
              }
              .onChange(of: loggingViewModel.fileLogLevel) {
                  enableFileLogs()
              }
              .starLanguage(viewModel.languageCode)
        }
        .defaultLaunchBehavior(.presented)
        .commands {
            StarCommands(viewModel: viewModel)
            CommandGroup(after: .windowList) {
                Divider()  // optional separator
                Button(localized("ui.blob_processing_window")) {
                    openWindow(id: StarApp.blobProcessingStepsWindowName)
                }
                  .keyboardShortcut("p", modifiers: [.option/*.command, .shift*/])
                Button(localized("ui.outlier_information_window")) {
                    openWindow(id: StarApp.outlierGroupTableWindowName) 
                }
                  .keyboardShortcut("o", modifiers: [.option])

                Button(localized("ui.alignment_information_window")) {
                    openWindow(id: StarApp.alignmentWindowName) 
                }
                .keyboardShortcut("a", modifiers: [.option])

                Button(localized("ui.debug_window")) {
                    openWindow(id: StarApp.debugWindowName) 
                }
                  .keyboardShortcut("d", modifiers: [.option])
            }
        }

        // this shows up as stars and wand in the upper right of the menu bar
        // always there when app is running, even when another app is used
        MenuBarExtra {
            ScrollView {
                VStack(spacing: 0) {
                    // maybe add buttons show show the different windows?
                    // maybe show overall progress monitor of some type?
                    Text(localized("ui.should_really_be_doing_something_here"))
                    Text(localized("ui.what_exactly"))
                    Text(localized("ui.not_sure"))
                }
            }
        } label: {
            Label(localized("ui.star"), systemImage: "wand.and.stars.inverse")
        }

    }
}

extension View {
    /// Make a window root follow the language the user picked in Star ▸ Language.
    ///
    /// Two separate things, both needed. `.id` forces SwiftUI to rebuild the subtree when the
    /// language changes: our strings come from `localized(...)`, an ordinary function call that
    /// SwiftUI cannot see into, so nothing else would tell it that every label on screen is now
    /// stale. `.environment(\.locale:)` is for what SwiftUI formats itself — numbers, dates,
    /// and any `Text` still holding a `LocalizedStringKey`.
    ///
    /// Layout direction is deliberately *not* flipped for Arabic and Urdu. It would have to be
    /// done for real — the frame editor, the filmstrip and the horizon painter all position
    /// content by hand against image coordinates, and mirroring the container without mirroring
    /// those would put the controls and the image they act on in different places. The text is
    /// translated and renders right-to-left within each label; the chrome stays where it is.
    func starLanguage(_ code: String) -> some View {
        self
          .id(code)
          .environment(\.locale, Locale(identifier: code))
    }
}

let OUTLIER_WINDOW_PREFIX = "Outliers"
var OTHER_WINDOW_TITLE: String { localized("ui.outlier_group_information") }

// allow intiazliation of an array with objects of some type that know their index
// XXX put this somewhere else
extension Array {
    public init(count: Int, elementMaker: (Int) -> Element) {
        self = (0 ..< count).map { i in elementMaker(i) }
    }
}



public final class GUILogHandler: LogHandler {

    public struct LogLine: Hashable {
        let time: Date
        let timeString: String
        let level: Log.Level
        let fileLocation: String
        let message: String
    //    let data: (any LogData)?

 
        public static func == (lhs: LogLine, rhs: LogLine) -> Bool {
            lhs.time == rhs.time &&
            lhs.level == rhs.level &&
            lhs.fileLocation == rhs.fileLocation &&
            lhs.message == rhs.message
        }

        // this entire log as a single line of string, without any newline
        public var logLine: String {
            "\(timeString) | \(level.emo) \(level) | \(fileLocation): \(message)"
        }
    }
    
    public let level: Log.Level
    private let viewModel: LoggingViewModel

    private let dateFormatter = DateFormatter()
    
    public init(at level: Log.Level, with viewModel: LoggingViewModel) {
        self.level = level
        self.viewModel = viewModel
        dateFormatter.dateFormat = "H:mm:ss.SSSS"
    }
       
    public func log(message: String,
                    at fileLocation: String,
                    with data: (any LogData)?,
                    at logLevel: Log.Level,
                    logTime: TimeInterval)
    {
        let date = Date(timeIntervalSinceReferenceDate: logTime)

        Task { @MainActor in
            let logLine = LogLine(time: date,
                                  timeString: self.dateFormatter.string(from: date),
                                  level: logLevel,
                                  fileLocation: fileLocation,
                                  message: message)

            viewModel.logs.append(logLine)

            // truncate gui logs at a certain level as they're kept in ram
            if viewModel.logs.count > viewModel.maxGUILogLines {
                let numberToRemove = viewModel.logs.count - viewModel.maxGUILogLines
                if numberToRemove < viewModel.logs.count {
                    viewModel.logs.removeFirst(numberToRemove)
                }
            }
        }
    }
}

