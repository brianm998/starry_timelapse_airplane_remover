import SwiftUI
import StarCore
import logging

@MainActor
struct InitialView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    @State private var previously_opened_sheet_showing_item: String = ""

    @State private var url1: URL? = nil
    @State private var url2: URL? = nil
    
    var body: some View {

        ZStack {

            if// let url1,
               let url2
            {
                SplitRevealVideoView(/*leftURL: url1, */rightURL: url2)
                  .background(.black)
            } else {
                Color.black
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            GeometryReader { geo in
                self.mainView
                  .frame(width: geo.size.width, height: geo.size.height)
            }
        }
          .onAppear {
              Task.detached {
/*
11_30_2024-fx3-aurora-topaz-star.mp4
11_30_2024-fx3-aurora-topaz.mp4
11_30_2024-fx3-aurora.mp4
11_30_2024-fx3.mp4
*/
                  /*
                  let _url1 = Bundle.main.url(forResource: "11_30_2024-fx3-airplanes",
                                              withExtension: "mp4")*/
                  let _url2 = Bundle.main.url(forResource: "11_30_2024-fx3-aurora-topaz-star",
                                              withExtension: "mp4")
                  Task { @MainActor in
                      //self.url1 = _url1
                      self.url2 = _url2
                  }
              }
              if viewModel.userPreferences.sortedSequenceList.count > 0 {
                  previously_opened_sheet_showing_item = viewModel.userPreferences.sortedSequenceList[0]
              }
          }
    }

    private var mainView: some View {
        @Bindable var viewModel = viewModel
        return VStack {
            Space(height: 40)
            Text("Welcome to Star v\(Config.latestVersion)")
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 20)
            Text("The Starry Timelapse Airplane Remover")
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 20)

            Button() {
                viewModel.showInfoDialog = true
            } label: {
                Text("Learn about Star").font(.largeTitle)
            }
              .buttonStyle(ShrinkingButton(.clear))
              .help("Tell me how to us this software") 
            Spacer()

            FinderStyleDropZone() { providers in
                handleDrop(providers: providers)
            }
              .frame(maxWidth: 1200, maxHeight: 800)

            Spacer()
            
            HStack {

                Spacer()
                Button(action: self.loadVideoToProcess) {
                    Text("Load Video").font(.largeTitle)
                }.buttonStyle(ShrinkingButton(.clear))
                  .help("Load a video to process.  Make sure lots of free space is available next to the video for intermediate files.")
                
                Spacer()
                Button(action: self.loadImageSequence) {
                    Text("Load Image Sequence").font(.largeTitle)
                }.buttonStyle(ShrinkingButton(.clear))
                  .help("Load an image sequence yet to be processed by star")
                Spacer()
                Button(action: self.loadConfig) {
                    Text("Load Config").font(.largeTitle)
                }.buttonStyle(ShrinkingButton(.clear))
                  .help("Load a json config file from a previous run of star")
                if viewModel.userPreferences.recentlyOpenedSequencelist.count > 0 {

                    Button(action: self.loadRecent) {
                        Text("Open Recent").font(.largeTitle)
                    }.buttonStyle(ShrinkingButton(.clear))
                      .help("open a recently processed sequence")
                    Picker("\u{27F6}", selection: $previously_opened_sheet_showing_item) {
                        let array = viewModel.userPreferences.sortedSequenceList
                        ForEach(array, id: \.self) { option in
                            Text(option)
                        }
                    }//.frame(maxWidth: 500)
                      .pickerStyle(.menu)
                }
                Spacer()
            }
              .sheet(isPresented: $viewModel.newReleaseSheetShowing) {
                  NewReleaseSheetView(isVisible: $viewModel.newReleaseSheetShowing,
                                      viewModel: viewModel)
              }
        }
          .background(.clear)
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: NSPasteboard.PasteboardType.self) {
                pasteboardItem, _ in
                if let pasteboardItem {
                    if let url = URL(string: pasteboardItem.rawValue) {

                        // handle json config files
                        // and directories full of files
                        // and later video files
                        
                        var isDir: ObjCBool = false
                        
                        if FileManager.default.fileExists(atPath: url.path,
                                                          isDirectory: &isDir) {
                            if isDir.boolValue {
                                // startup with a new sequence dir
                                Task { @MainActor in
                                    startupWithSequenceDir(url.path)
                                }
                            } else if url.path.hasSuffix(".json") {
                                // try to parse out a config file
                                do {
                                    Task { @MainActor in
                                        let config = try ConfigManager(configFilename: url.path)
                                        try await self.viewModel.startup(withConfig: config)
                                        self.viewModel.userPreferences.justOpened(filename: url.path) 
                                    }
                                } catch {
                                    Log.e("cannot load \(url.path): \(error)")
                                    // XXX show view error
                                    Task { @MainActor in
                                        self.handle(error: "\(error)")
                                    }
                                }
                            } else {
                                // XXX handle video drops here
                                Task { @MainActor in
                                    startupWithVideoToProcess(url.path)
                                    //self.handle(error: "Unsupported file type \(url.path)")
                                }
                            }
                        } else {
                            Task { @MainActor in
                                self.handle(error: "File does not exist: \(url.path)")
                            }
                        }
                    }
                }
            }
        }
        
        return false
    }

    func handle(error: String) {
        self.viewModel.report(error: error)
        self.viewModel.imageSequence = nil
        self.viewModel.isLoadingImageSequence = false
    }
    
    func loadConfig()  {
        Log.d("load config")

        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        let response = openPanel.runModal()
        if response == .OK {
            if let returnedUrl = openPanel.url
            {
                let path = returnedUrl.path
                Log.d("url path \(path)")

                viewModel.eraserTask = Task.detached(priority: .userInitiated) {
                    do {
                        try await viewModel.startup(withConfigFile: path)
                        Task { @MainActor in
                            viewModel.imageSequence?.initialLoadInProgress = true
                        }
                        
                       // Log.d("viewModel.eraser \(String(describing: await viewModel.eraser))")
                        try await viewModel.imageSequence?.eraser?.run()
                    } catch {
                        Log.e("\(error)")
                        await MainActor.run {
                            self.handle(error: "\(error)")
                        }
                    }
                }
            }
        }
    }

    func loadVideoToProcess() {
        Log.d("load video to process")
        let openPanel = NSOpenPanel()
        //openPanel.allowedFileTypes = ["json"]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        let response = openPanel.runModal()
        if response == .OK {
            if let returnedUrl = openPanel.url {
                let path = returnedUrl.path
                Log.d("url path \(path)")

                startupWithVideoToProcess(path)
            }
        }
    }
    
    func loadImageSequence() {
        Log.d("load image sequence")
        let openPanel = NSOpenPanel()
        //openPanel.allowedFileTypes = ["json"]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        let response = openPanel.runModal()
        if response == .OK {
            if let returnedUrl = openPanel.url {
                let path = returnedUrl.path
                Log.d("url path \(path)")
                
                startupWithSequenceDir(path)
            }
        }
    }

    func startupWithVideoToProcess(_ path: String) {
        viewModel.eraserTask = Task.detached(priority: .userInitiated) {
            do {
                try await viewModel.startup(withVideoToProcess: path)
                Task { @MainActor in
                    viewModel.imageSequence?.initialLoadInProgress = true
                }
                try await viewModel.imageSequence?.eraser?.run()
            } catch {
                Log.e("\(error)")
                await MainActor.run {
                    self.handle(error: "\(error)")
                }
            }
        }
    }

    func startupWithSequenceDir(_ path: String) {
        viewModel.eraserTask = Task.detached(priority: .userInitiated) {
            do {
                try await viewModel.startup(withNewImageSequence: path)
                Task { @MainActor in
                    viewModel.imageSequence?.initialLoadInProgress = true
                }
                try await viewModel.imageSequence?.eraser?.run()
            } catch {
                Log.e("\(error)")
                await MainActor.run {
                    self.handle(error: "\(error)")
                }
            }
        }
    }

    func loadRecent() {
        Log.d("load image sequence")
        
        viewModel.eraserTask = Task.detached(priority: .userInitiated) {
            do {
              try await viewModel.startup(withConfigFile: previously_opened_sheet_showing_item)
                Task { @MainActor in
                    viewModel.imageSequence?.initialLoadInProgress = true
                }
                try await viewModel.imageSequence?.eraser?.run()
            } catch {
                Log.e("\(error)")
                await MainActor.run {
                    self.handle(error: "\(error)")
                }
            }
        }
    }
}





import SwiftUI
@preconcurrency import AVFoundation
import AppKit

struct SplitRevealVideoView: View {
//    let leftURL: URL
    let rightURL: URL

    @StateObject private var vm: VM
    @State private var dragFraction: CGFloat = 0.25 // 0..1
    @State private var autoAnimating = true // controls pendulum motion

    private let minFraction: CGFloat = 0.25
    private let maxFraction: CGFloat = 0.35

    init(/*leftURL: URL, */rightURL: URL) {
//        self.leftURL = leftURL
        self.rightURL = rightURL
        _vm = StateObject(wrappedValue: VM(/*left: leftURL, */right: rightURL))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                /*
                // Left video (visible on left side up to dragFraction)
                VideoLayerRepresentable(player: vm.playerLeft,
                                        revealFraction: dragFraction,
                                        maskSide: .left)
*/
                // Right video (visible on right side after dragFraction)
                VideoLayerRepresentable(player: vm.playerRight,
                                        revealFraction: 1/*dragFraction*/,
                                        maskSide: .right)

                // Divider handle
/*
                handle(in: geo.size)
                  .position(x: geo.size.width * dragFraction,
                  y: geo.size.height / 2)
                  
 */
            }
              .frame(width: geo.size.width, height: geo.size.height)
//              .position(x: geo.size.width / 2, y: geo.size.height / 2)
            // global drag gesture across the fitted area
/*
              .cursor(.resizeLeftRight)
              .gesture(
                DragGesture(minimumDistance: 0)
                  .onChanged { value in

                      if autoAnimating {
                          autoAnimating = false // stop pendulum as soon as user interacts
                      }
                      
                      let clampedX = min(max(0, value.location.x), geo.size.width)
                      dragFraction = clampedX / geo.size.width
                  }
                  )         .contentShape(Rectangle()) // Make gesture active only inside visible video frame
 */
              .onAppear {
                  vm.prepareAndPlay()
//                  startPendulum()
              }
              .onDisappear {
                  vm.pause()
              }
        }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startPendulum() {
        guard autoAnimating else { return }

        // Start from current value, move to opposite bound
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            dragFraction = (dragFraction == minFraction) ? maxFraction : minFraction
        }
    }

    
    @ViewBuilder
    private func handle(in size: CGSize) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.95))
            .frame(width: 4, height: size.height)
            .cornerRadius(2)
            .shadow(radius: 2)
            .opacity(0.333)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
            )
    }

    /// Fit the video inside 'container' while preserving aspect ratio.
    private func fitSize(container: CGSize, aspectRatio: CGFloat) -> CGSize {
        guard container.width > 0 && container.height > 0 else { return .zero }
        let containerAspect = container.width / container.height
        if containerAspect > aspectRatio {
            // container wider -> fit by height
            let h = container.height
            return CGSize(width: h * aspectRatio, height: h)
        } else {
            // container taller -> fit by width
            let w = container.width
            return CGSize(width: w, height: w / aspectRatio)
        }
    }

    // MARK: - ViewModel
    /// Main-thread-only ObservableObject that manages players and aspect ratio.
    @MainActor
    final class VM: ObservableObject {
//        let playerLeft = AVPlayer()
        let playerRight = AVPlayer()
        @Published var aspectRatio: CGFloat = 16.0 / 9.0

//        private let leftURL: URL
        private let rightURL: URL

        init(/*left: URL, */right: URL) {
            //self.leftURL = left
            self.rightURL = right
            loadAspectRatio()

            [/*playerLeft, */playerRight].forEach { player in
                NotificationCenter.default.addObserver(
                  forName: .AVPlayerItemDidPlayToEndTime,
                  object: player.currentItem,
                  queue: .main
                ) { _ in
                    player.seek(to: .zero)
                    player.play()
                }
            }
        }

        private func loadAspectRatio() {
            // Perform work off the main thread to avoid blocking UI
            DispatchQueue.global(qos: .background).async { [rightURL] in
                let asset = AVAsset(url: rightURL)
                // try to read first video track synchronously (may be available)
                let tracks = asset.tracks(withMediaType: .video)
                if let track = tracks.first {
                    let size = track.naturalSize.applying(track.preferredTransform)
                    let w = abs(size.width)
                    let h = abs(size.height)
                    if w > 0, h > 0 {
                        DispatchQueue.main.async {
                            self.aspectRatio = CGFloat(w / h)
                        }
                        return
                    }
                }
                // Fallback: try the async KVO path if above didn't yield
                asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
                    var err: NSError?
                    let status = asset.statusOfValue(forKey: "tracks", error: &err)
                    if status == .loaded {
                        if let track = asset.tracks(withMediaType: .video).first {
                            let size = track.naturalSize.applying(track.preferredTransform)
                            let w = abs(size.width)
                            let h = abs(size.height)
                            if w > 0, h > 0 {
                                DispatchQueue.main.async {
                                    self.aspectRatio = CGFloat(w / h)
                                }
                            }
                        }
                    }
                }
            }
        }

        func prepareAndPlay() {
//            let assetL = AVAsset(url: leftURL)
            let assetR = AVAsset(url: rightURL)
//            let itemL = AVPlayerItem(asset: assetL)
            let itemR = AVPlayerItem(asset: assetR)

  //          playerLeft.replaceCurrentItem(with: itemL)
            playerRight.replaceCurrentItem(with: itemR)

            // Use the same master clock for both players
            let masterClock = CMClockGetHostTimeClock()
//            playerLeft.masterClock = masterClock
            playerRight.masterClock = masterClock

            // Seek both exactly to zero before starting
            let zeroTime = CMTime(seconds: 0, preferredTimescale: 600)
            let group = DispatchGroup()

//            group.enter()
//            playerLeft.seek(to: zeroTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in group.leave() }
            group.enter()
            playerRight.seek(to: zeroTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in group.leave() }

            group.notify(queue: .main) {
                // Start them together
//                self.playerLeft.play()
                self.playerRight.play()
            }
        }

        func pause() {
//            playerLeft.pause()
            playerRight.pause()
        }
    }
}

// Mark VM sendable for interaction with @Sendable contexts.
// We used @MainActor above and the class is only mutated on main, so this is safe.
extension SplitRevealVideoView.VM: @unchecked Sendable { }

// MARK: - Video layer representable

import SwiftUI
import AVFoundation
import AppKit

private enum MaskSide { case left, right, none }

private struct VideoLayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    var revealFraction: CGFloat // 0..1
    var maskSide: MaskSide

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.player = player
        view.revealFraction = revealFraction
        view.maskSide = maskSide
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.player = player
        nsView.revealFraction = revealFraction
        nsView.maskSide = maskSide
    }

    // Custom NSView subclass that manages AVPlayerLayer and mask in layout()
    class PlayerContainerView: NSView {
        var playerLayer: AVPlayerLayer?
        var maskLayer: CALayer?

        var player: AVPlayer? {
            didSet {
                if oldValue !== player {
                    playerLayer?.removeFromSuperlayer()
                    playerLayer = nil
                    maskLayer = nil

                    if let player = player {
                        let pl = AVPlayerLayer(player: player)
                        pl.videoGravity = .resizeAspectFill
                        pl.masksToBounds = true
                        layer?.addSublayer(pl)
                        playerLayer = pl

                        let mask = CALayer()
                        mask.backgroundColor = NSColor.black.cgColor
                        pl.mask = mask
                        maskLayer = mask
                    }
                    needsLayout = true
                }
            }
        }

        var revealFraction: CGFloat = 1.0 {
            didSet {
                if revealFraction != oldValue {
                    needsLayout = true
                }
            }
        }

        var maskSide: MaskSide = .none {
            didSet {
                if maskSide != oldValue {
                    needsLayout = true
                }
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
            layer = CALayer()
            layer?.masksToBounds = true
        }

        override func layout() {
            super.layout()
            guard let playerLayer = playerLayer, let maskLayer = maskLayer else { return }
            playerLayer.frame = bounds

            let width = bounds.width
            let height = bounds.height
            let clamped = min(max(0.0, revealFraction), 1.0)

            switch maskSide {
            case .left:
                maskLayer.frame = CGRect(x: 0, y: 0, width: width * clamped, height: height)
            case .right:
                let x = width * clamped
                maskLayer.frame = CGRect(x: x, y: 0, width: width - x, height: height)
            case .none:
                maskLayer.frame = bounds
            }

            if maskLayer.frame.width <= 0 || maskLayer.frame.height <= 0 {
                playerLayer.mask = nil
            } else {
                playerLayer.mask = maskLayer
            }
        }
    }
}



