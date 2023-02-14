//
//  ContentView.swift
//  ntar_gui
//
//  Created by Brian Martin on 2/1/23.
//

import Foundation
import SwiftUI
import Cocoa
import NtarCore
import Zoomable

// XXX Fing global :(
fileprivate var video_play_timer: Timer?

fileprivate var current_video_frame = 0

enum FrameViewMode: String, Equatable, CaseIterable {
    case original
    case processed
    case testPainted

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

// the overall level of the app
struct ContentView: View {
    @ObservedObject var viewModel: ViewModel
    @State private var showOutliers = false

    // enum for how we show each frame
    @State private var frameViewMode = FrameViewMode.original
    // show only lower res previews instead of full res images
    @State private var previewMode = true
    
    @State private var selection_causes_painting = true
    @State private var running = false
    @State private var drag_start: CGPoint?
    @State private var drag_end: CGPoint?
    @State private var isDragging = false
    @State private var background_brightness: Double = 0.33
    @State private var background_color: Color = .gray

    @State private var loading_outliers = false
    @State private var loading_all_outliers = false
    @State private var rendering_current_frame = false
    @State private var rendering_all_frames = false

    @State private var fast_skip_amount = 20
    @State private var video_playback_framerate = 10
    @State private var video_playing = false

    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        let scaling_anchor = UnitPoint(x: 0.75, y: 0.75)
        GeometryReader { top_geometry in
            ScrollViewReader { scroller in
                VStack {
                    currentFrameView()
                    if !previewMode {
                        HStack {
                            Text(viewModel.label_text).font(.largeTitle)
                            let count = viewModel.currentFrameView.outlierViews.count
                            if count > 0 {
                                Text("has \(count) outliers").font(.largeTitle)
                            }
                        }
                    }
                    VStack {
                        HStack {
                            if !running {
                                let action = {
                                    running = true
                                    viewModel.initial_load_in_progress = true
                                    Task.detached(priority: .background) {
                                        do {
                                            try await viewModel.eraser?.run()
                                        } catch {
                                            Log.e("\(error)")
                                        }
                                    }
                                }
                                Button(action: action) {
                                    Text("START").font(.largeTitle)
                                }.buttonStyle(PlainButtonStyle())
                            } else {
                                if viewModel.initial_load_in_progress ||
                                   loading_outliers                   ||
                                   loading_all_outliers               || 
                                   rendering_current_frame            ||
                                   rendering_all_frames
                                {
                                    ProgressView()
                                      .scaleEffect(1, anchor: .center)
                                      .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                                    Spacer()
                                      .frame(maxWidth: 50)
                                }

                                // video playback and frame advancement buttons
                                videoPlaybackButtons(scroller)
                            }

                            VStack {
                                /*
                                Picker("go to frame", selection: $viewModel.current_index) {
                                    ForEach(0 ..< viewModel.frames.count, id: \.self) {
                                        Text("frame \($0)")
                                    }
                                }
                                  .frame(maxWidth: 200)
                                  .onChange(of: viewModel.current_index) { pick in
                                      Log.d("pick \(pick)")
                                      self.transition(toFrame: viewModel.frames[pick],
                                                      from: viewModel.currentFrame,
                                                      withScroll: scroller)
                                  }
                                */
                                Picker("Fast Skip", selection: $fast_skip_amount) {
                                    ForEach(0 ..< 51) {
                                        Text("\($0) frames")
                                    }
                                }.frame(maxWidth: 200)
                                let frame_rates = [5, 10, 15, 20, 25, 30]
                                Picker("Frame Rate", selection: $video_playback_framerate) {
                                    ForEach(frame_rates, id: \.self) {
                                        Text("\($0) fps")
                                    }
                                }.frame(maxWidth: 200)
                            }
                            
                            paintAllButton()
                            clearAllButton()

                            toggleViews()
/*                            
                            Text("background")
                            Slider(value: $background_brightness, in: 0...100) { editing in
                                Log.d("editing \(editing) background_brightness \(background_brightness)")
                                background_color = Color(white: background_brightness/100)
                                viewModel.objectWillChange.send()
                            }
                              .frame(maxWidth: 100, maxHeight: 30)
  */                          
                            //load all outlier button
                            loadAllOutliersButton()
                            renderCurrentFrameButton()
                            renderAllFramesButton()
                            
                        }
                        Spacer().frame(maxHeight: 30)
                        // the filmstrip at the bottom
                        filmstrip()
                        Spacer().frame(maxHeight: 10)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
              .padding()
              .background(background_color)
        }
    }

    // shows either a zoomable view of the current frame
    // or a place holder when we have no image for it yet
    func currentFrameView() -> some View {
        HStack {
            //if let frame_image = viewModel.frames[viewModel.current_index].image {
            if let frame_image = viewModel.current_frame_image {//viewModel.frames[viewModel.current_index].image {
                GeometryReader { geometry in
                    let min = geometry.size.height/viewModel.frame_height
                    let max = min < 1 ? 1 : min
                    ZoomableView(size: CGSize(width: viewModel.frame_width,
                                              height: viewModel.frame_height),
                                 min: min,
                                 max: max,
                                 showsIndicators: true)
                    {
                        // the currently visible frame
                        self.frameView(frame_image)
                    }
                }
            } else {
                // XXX pre-populate this crap as an image
                ZStack {
                    Rectangle()
                      .foregroundColor(.yellow)
                      .frame(maxWidth: viewModel.frame_width, maxHeight: viewModel.frame_height)
                    Text(viewModel.no_image_explaination_text)
                }
            }
        }
    }
    
    // this is the main frame with outliers on top of it
    func frameView( _ image: Image) -> some View {
        ZStack {
            image

            if showOutliers {
                // XXX these VVV are wrong VVV somehow
                let outlierViews = viewModel.currentFrameView.outlierViews
                ForEach(0 ..< outlierViews.count, id: \.self) { idx in
                    if idx < outlierViews.count {
                        let outlierViewModel = outlierViews[idx]
                        
                        let frame_center_x = outlierViewModel.frame_width/2
                        let frame_center_y = outlierViewModel.frame_height/2
                        let outlier_center = outlierViewModel.bounds.center

                        let will_paint = outlierViewModel.group.shouldPaint == nil ? false :
                          outlierViewModel.group.shouldPaint!.willPaint

                        Image(nsImage: outlierViewModel.image)
                          .renderingMode(.template) // makes this VV color work
                          .foregroundColor(will_paint ? .red : .green)
                          .offset(x: CGFloat(outlier_center.x - frame_center_x),
                                  y: CGFloat(outlier_center.y - frame_center_y))
                          // tap gesture toggles paintability of the tapped group
                          .onTapGesture {
                              if let origShouldPaint = outlierViewModel.group.shouldPaint {
                                  // change the paintability of this outlier group
                                  // set it to user selected opposite previous value
                                  let reason = PaintReason.userSelected(!origShouldPaint.willPaint)
                                  outlierViewModel.group.shouldPaint(reason)
                                  
                                  // update the view model so it shows up on screen
                                  self.viewModel.update()
                              } else {
                                  Log.e("WTF, not already set to paint??")
                              }
                          }
                     }
                }
            }
            // this is the selection overlay
            if isDragging,
               let drag_start = drag_start,
               let drag_end = drag_end
            {
                let width = abs(drag_start.x-drag_end.x)
                let height = abs(drag_start.y-drag_end.y)

                let drag_x_offset = drag_end.x > drag_start.x ? drag_end.x : drag_start.x
                let drag_y_offset = drag_end.y > drag_start.y ? drag_end.y : drag_start.y

                Rectangle()
                  .fill((selection_causes_painting ?
                          Color.red :
                          Color.green).opacity(0.2))
                  .overlay(
                    Rectangle()
                      .stroke(style: StrokeStyle(lineWidth: 2))
                      .foregroundColor((selection_causes_painting ?
                                          Color.red : Color.green).opacity(0.8))
                  )                
                  .frame(width: width, height: height)
                  .offset(x: CGFloat(-viewModel.frame_width/2) + drag_x_offset - width/2,
                          y: CGFloat(-viewModel.frame_height/2) + drag_y_offset - height/2)

            }
        }
        // add a drag gesture to allow selecting outliers for painting or not
        // XXX selecting and zooming conflict with eachother
          .gesture(DragGesture()
                   .onChanged { gesture in
                       isDragging = true
                       let location = gesture.location
                       if let drag_start = drag_start {
                           // updating during drag is too slow
                           drag_end = location
                       } else {
                           drag_start = gesture.startLocation
                       }
                       //Log.d("location \(location)")
                   }
                   .onEnded { gesture in
                       isDragging = false
                       let end_location = gesture.location
                       if let drag_start = drag_start {
                           Log.d("end location \(end_location) drag start \(drag_start)")
                           Task {
                               if let frame = viewModel.currentFrame {
                                   await frame.userSelectAllOutliers(toShouldPaint: selection_causes_painting,
                                                                     between: drag_start,
                                                                     and: end_location)
                               }
                               viewModel.update()
                           }
                       }
                       drag_start = nil
                       drag_end = nil
                   }
          )
    }

    // the view for each frame in the filmstrip at the bottom
    func filmStripView(forFrame frame_index: Int) -> some View {
        var bg_color: Color = .yellow
        if let frame = viewModel.frame(atIndex: frame_index) {
            //            if frame.outlierGroupCount() > 0 {
            //                bg_color = .red
            //            } else {
            bg_color = .green
            //            }
        }
        return VStack(alignment: .leading) {
            Spacer().frame(maxHeight: 8)
            HStack{
                Spacer().frame(maxWidth: 10)
                Text("\(frame_index)").foregroundColor(.white)
            }.frame(maxHeight: 10)
            if frame_index >= 0 && frame_index < viewModel.frames.count {
                let frameView = viewModel.frames[frame_index]
                let stroke_width: CGFloat = 4
                if viewModel.current_index == frame_index {

                    frameView.thumbnail_image
                      .foregroundColor(.orange)
                    
                } else {
                    frameView.thumbnail_image
                }
            }
            Spacer().frame(maxHeight: 8)
        }
          .frame(minWidth: CGFloat((viewModel.config?.thumbnail_width ?? 80) + 8),
                 minHeight: CGFloat((viewModel.config?.thumbnail_height ?? 50) + 30))
           // highlight the selected frame
          .background(viewModel.current_index == frame_index ? Color(white: 0.45) : Color(white: 0.22))
          .onTapGesture {
        // XXX move this out 
        viewModel.label_text = "loading..."
        // XXX set loading image here
              // grab frame and try to show it
              let frame_view = viewModel.frames[frame_index]

              let current_frame = viewModel.currentFrame
              self.transition(toFrame: frame_view, from: current_frame)
          }

    }

    // used when advancing between frames
    func saveToFile(frame frame_to_save: FrameAirplaneRemover, completionClosure: @escaping () -> Void) {
        if let frameSaveQueue = viewModel.frameSaveQueue {
            frameSaveQueue.readyToSave(frame: frame_to_save, completionClosure: completionClosure)
        } else {
            Log.e("FUCK")
            fatalError("SETUP WRONG")
        }
    }

    let button_size: CGFloat = 50
    
    func clearAllButton() -> some View {
        Button(action: {
            Task {
                await viewModel.currentFrame?.userSelectAllOutliers(toShouldPaint: false)
                await renderCurrentFrame()
                viewModel.update()
            }
        }) {
            Text("Clear All").font(.largeTitle)
        }.buttonStyle(PlainButtonStyle())
          .keyboardShortcut("c", modifiers: [])
    }
    
    func paintAllButton() -> some View {
        Button(action: {
            Task {
                await viewModel.currentFrame?.userSelectAllOutliers(toShouldPaint: true)
                await renderCurrentFrame()
                viewModel.update()
            }
        }) {
            Text("Paint All").font(.largeTitle)
        }.buttonStyle(PlainButtonStyle())
          .keyboardShortcut("p", modifiers: [])
    }
    
    func filmstrip() -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(0..<viewModel.image_sequence_size, id: \.self) { frame_index in
                    self.filmStripView(forFrame: frame_index)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: 50)
    }

    func renderAllFramesButton() -> some View {
        let action: () -> Void = {
            Task {
                var number_to_save = 0
                self.rendering_all_frames = true
                for frameView in viewModel.frames {
                    if let frame = frameView.frame,
                       let frameSaveQueue = viewModel.frameSaveQueue
                    {
                        number_to_save += 1
                        frameSaveQueue.saveNow(frame: frame) {
                            await viewModel.refresh(frame: frame)
                            /*
                            if frame.frame_index == viewModel.current_index {
                                refreshCurrentFrame()
                                }
                             */
                            number_to_save -= 1
                            if number_to_save == 0 {
                                self.rendering_all_frames = false
                            }
                        }
                    }
                }
                // XXX this executes almost immediately after being set to true above,
                // need to wait until the frame save queue is done..
            }
        }
        
        return Button(action: action) {
            Text("Render All Frames").font(.largeTitle)
        }.buttonStyle(PlainButtonStyle())
    }

    func renderCurrentFrame() async {
        if let frame = viewModel.currentFrame,
           let frameSaveQueue = viewModel.frameSaveQueue
        {
            self.rendering_current_frame = true
            frameSaveQueue.saveNow(frame: frame) {
                await viewModel.refresh(frame: frame)
                refreshCurrentFrame()
                self.rendering_current_frame = false
            }
        }
    }
    
    func renderCurrentFrameButton() -> some View {
        let action: () -> Void = {
            Task { await self.renderCurrentFrame() }
        }
        
        return Button(action: action) {
            Text("Render This Frame").font(.largeTitle)
        }.buttonStyle(PlainButtonStyle())
    }
    
    func loadAllOutliersButton() -> some View {
        let action: () -> Void = {
            Task {
                do {
                    var current_running = 0
                    let start_time = Date().timeIntervalSinceReferenceDate
                    try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                        let max_concurrent = viewModel.config?.numConcurrentRenders ?? 10
                        // this gets "Too many open files" with more than 2000 images :(
                        loading_all_outliers = true
                        Log.d("foobar starting")
                        for frameView in viewModel.frames {
                            Log.d("frame \(frameView.frame_index) attempting to load outliers")
                            var did_load = false
                            while(!did_load) {
                                if current_running < max_concurrent {
                                    Log.d("frame \(frameView.frame_index) attempting to load outliers")
                                    if let frame = frameView.frame {
                                        Log.d("frame \(frameView.frame_index) adding task to load outliers")
                                        current_running += 1
                                        did_load = true
                                        taskGroup.addTask(priority: .userInitiated) {
                                            // XXX style the button during this flow?
                                            Log.d("actually loading outliers for frame \(frame.frame_index)")
                                            try await frame.loadOutliers()
                                            // XXX set this in the view model

                                            Task {
                                                await MainActor.run {
                                                    Task {
                                                        await viewModel.setOutlierGroups(forFrame: frame)
                                                    }
                                                }
                                            }
                                        }
                                    } else {
                                        Log.d("frame \(frameView.frame_index) no frame, can't load outliers")
                                    }
                                } else {
                                    Log.d("frame \(frameView.frame_index) waiting \(current_running)")
                                    try await taskGroup.next()
                                    current_running -= 1
                                    Log.d("frame \(frameView.frame_index) done waiting \(current_running)")
                                }
                            }
                        }
                        do {
                            try await taskGroup.waitForAll()
                        } catch {
                            Log.e("\(error)")
                        }
                        
                        let end_time = Date().timeIntervalSinceReferenceDate
                        loading_all_outliers = false
                        Log.d("foobar loaded outliers for \(viewModel.frames.count) frames in \(end_time - start_time) seconds")
                    }                                 
                } catch {
                    Log.e("\(error)")
                }
            }
        }
        
        return Button(action: action) {
            Text("Load All Outliers").font(.largeTitle)
        }.buttonStyle(PlainButtonStyle())
    }
    
    // an HStack of buttons to advance backwards and fowards through the sequence
    func videoPlaybackButtons(_ scroller: ScrollViewProxy) -> some View {

        // XXX these should really use modifiers but those don't work :(
        let start_shortcut_key: KeyEquivalent = "b" // make this bottom arror
        let fast_previous_shortut_key: KeyEquivalent = "z"
        let previous_shortut_key: KeyEquivalent = .leftArrow
        let fast_next_shortcut_key: KeyEquivalent = "x"
        let end_button_shortcut_key: KeyEquivalent = "e" // make this top arror
        
        return HStack {
            // start button
            button(named: "backward.end.fill",
                   shortcutKey: start_shortcut_key,
                   color: .white,
                   toolTip: """
                     go to start of sequence
                     (keyboard shortcut '\(start_shortcut_key.character)')
                     """)
            {
                self.transition(toFrame: viewModel.frames[0],
                                from: viewModel.currentFrame,
                                withScroll: scroller)
            }
            
            
            // fast previous button
            button(named: "backward.fill",
                   shortcutKey: fast_previous_shortut_key,
                   color: .white,
                   toolTip: """
                     back \(fast_skip_amount) frames
                     (keyboard shortcut '\(fast_previous_shortut_key.character)')
                     """)
            {
                self.transition(numberOfFrames: -fast_skip_amount,
                                withScroll: scroller)
            }
            
            // previous button
            button(named: "backward.frame.fill",
                   shortcutKey: previous_shortut_key,
                   color: .white,
                   toolTip: """
                     back one frame
                     (keyboard shortcut left arrow)
                     """)
            {
                self.transition(numberOfFrames: -1,
                                withScroll: scroller)
            }

            // play/pause button
            button(named: video_playing ? "pause.fill" : "play.fill", // pause.fill
                   shortcutKey: " ",
                   color: .yellow,
                   toolTip: """
                     Play / Pause
                     """)
            {
                self.togglePlay(scroller)
                Log.w("play button not yet implemented")
            }
            
            // next button
            button(named: "forward.frame.fill",
                   shortcutKey: .rightArrow,
                   color: .white,
                   toolTip: """
                     forward one frame
                     (keyboard shortcut right arrow)
                     """)
            {
                self.transition(numberOfFrames: 1,
                                withScroll: scroller)
            }
            
            // fast next button
            button(named: "forward.fill",
                   shortcutKey: fast_next_shortcut_key,
                   color: .white,
                   toolTip: """
                     forward \(fast_skip_amount) frames
                     (keyboard shortcut '\(fast_next_shortcut_key.character)')
                     """)
            {
                self.transition(numberOfFrames: fast_skip_amount,
                                withScroll: scroller)
            }
            
            
            // end button
            button(named: "forward.end.fill",
                   shortcutKey: end_button_shortcut_key,
                   color: .white,
                   toolTip: """
                     advance to end of sequence
                     (keyboard shortcut '\(end_button_shortcut_key.character)')
                     """)
            {
                self.transition(toFrame: viewModel.frames[viewModel.frames.count-1],
                                from: viewModel.currentFrame,
                                withScroll: scroller)
            }
        }
        
    }

    func togglePlay(_ scroller: ScrollViewProxy) {
        self.video_playing = !self.video_playing
        if video_playing {
            self.showOutliers = false
            Log.d("playing @ \(video_playback_framerate) fps")
            current_video_frame = viewModel.current_index
            video_play_timer = Timer.scheduledTimer(withTimeInterval: 1/Double(video_playback_framerate),
                                                    repeats: true) { timer in


                let current_frame_view = self.viewModel.frames[current_video_frame]
                
                switch self.frameViewMode {
                case .original:
                    viewModel.current_frame_image = current_frame_view.preview_image.resizable()
                case .processed:
                    viewModel.current_frame_image = current_frame_view.processed_preview_image.resizable()
                case .testPainted:
                    viewModel.current_frame_image = current_frame_view.test_paint_preview_image.resizable()
                }
            //self.viewModel.current_frame_image =
            //                  .preview_image.resizable()
                current_video_frame += 1
                if current_video_frame >= self.viewModel.frames.count {
                    video_play_timer?.invalidate()
                    viewModel.current_index = current_video_frame
                    scroller.scrollTo(viewModel.current_index)
                    video_playing = false
                }
            }
        } else {
            self.showOutliers = true // XXX maybe track previous state before setting it off at start of video play?
            video_play_timer?.invalidate()
            Log.d("not playing")
            // scroller usage here
            viewModel.current_index = current_video_frame
            scroller.scrollTo(viewModel.current_index)
        }
    }

    
    func toggleViews() -> some View {
        HStack() {
            VStack(alignment: .leading) {
                Toggle("show outliers", isOn: $showOutliers)
                  .keyboardShortcut("o", modifiers: [])
                  .onChange(of: showOutliers) { shouldShow in
                      Log.d("show outliers shouldShow \(shouldShow)")
                      if shouldShow {
                          refreshCurrentFrame()
                      }
                  }
                Toggle("selection causes paint", isOn: $selection_causes_painting)
                  .keyboardShortcut("t", modifiers: []) // XXX find better modifier
            }
            VStack(alignment: .leading) {
                let frameViewModes: [FrameViewMode] = [.original, .processed, .testPainted]
                Picker("view mode", selection: $frameViewMode) {
                    // XXX expand this to not use allCases, but only those that we have files for
                    // i.e. don't show test-paint when the sequence wasn't test painted
                    ForEach(FrameViewMode.allCases, id: \.self) { value in
                        Text(value.localizedName).tag(value)
                    }
                }
                  .frame(maxWidth: 200)
                  .onChange(of: frameViewMode) { pick in
                      Log.d("pick \(pick)")
                      refreshCurrentFrame()
                      /*
                      self.transition(toFrame: viewModel.frames[pick],
                                      from: viewModel.currentFrame,
                                      withScroll: scroller)
                                      */
                    
                  }

                
                Toggle("preview mode", isOn: $previewMode)
                  .onChange(of: !previewMode) { mode_on in
                      refreshCurrentFrame()
                  }
/*
                Toggle("preview mode", isOn: $showPreviewMode)
                  .keyboardShortcut("b", modifiers: [])
                  .onChange(of: showPreviewMode) { mode_on in
                      if mode_on {
                          showOutliers = false
                          showProcessedPreviewMode = false
                          showTestPaintPreviewMode = false
                          !previewMode = false

                          viewModel.current_frame_image = viewModel.frames[viewModel.current_index].preview_image.resizable()
                      } 
                  }
                Toggle("processed mode", isOn: $showProcessedPreviewMode)
                  .onChange(of: showProcessedPreviewMode) { mode_on in
                      if mode_on {
                          showOutliers = false
                          showPreviewMode = false
                          showTestPaintPreviewMode = false

                          viewModel.current_frame_image = viewModel.frames[viewModel.current_index].processed_preview_image.resizable()
                      }
                  }                
                Toggle("test paint mode", isOn: $showTestPaintPreviewMode)
                  .onChange(of: showTestPaintPreviewMode) { mode_on in
                      if mode_on {
                          showOutliers = false
                          showPreviewMode = false
                          showProcessedPreviewMode = false
                          viewModel.current_frame_image = viewModel.frames[viewModel.current_index].test_paint_preview_image.resizable()
                      }
                 }
 */
            }
        }
    }

    func buttonImage(_ name: String) -> some View {
        return Image(systemName: name)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: button_size, maxHeight: button_size)
    }
    
    func button(named button_name: String,
                shortcutKey: KeyEquivalent,
                modifiers: EventModifiers = [],
                color: Color,
                toolTip: String,
                action: @escaping () -> Void) -> some View
    {
        //Log.d("button \(button_name) using modifiers \(modifiers)")
        return ZStack {
            Button("", action: action)
              .opacity(0)
              .keyboardShortcut(shortcutKey, modifiers: modifiers)
            
            Button(action: action) {
                buttonImage(button_name)
            }
              .buttonStyle(PlainButtonStyle())                            
              .help(toolTip)
              .foregroundColor(color)
        }
    }

    func transition(numberOfFrames: Int,
                    withScroll scroller: ScrollViewProxy? = nil)
    {
        let current_frame = viewModel.currentFrame

        var new_index = viewModel.current_index + numberOfFrames
        if new_index < 0 { new_index = 0 }
        if new_index >= viewModel.frames.count {
            new_index = viewModel.frames.count-1
        }
        let new_frame_view = viewModel.frames[new_index]
        
        self.transition(toFrame: new_frame_view,
                        from: current_frame,
                        withScroll: scroller)
    }

    func refreshCurrentFrame() {
        // XXX maybe don't wait for frame?
        Log.d("refreshCurrentFrame \(viewModel.current_index)")
        let new_frame_view = viewModel.frames[viewModel.current_index]
        if let next_frame = new_frame_view.frame {
            // always stick the preview image in there first if we have it

            // XXX this can cause flashing sometimes when refresh is called too many times in a row

            // keep track of the previous current frame and the previous frame view mode
            // and if they're the same, then don't show the preview
            
            switch self.frameViewMode {
            case .original: // XXX do we need add .resizable() here, and is it slowing us down?
                viewModel.current_frame_image = new_frame_view.preview_image.resizable()
            case .processed:
                viewModel.current_frame_image = new_frame_view.processed_preview_image.resizable()
            case .testPainted:
                viewModel.current_frame_image = new_frame_view.test_paint_preview_image.resizable()
            }
            if !previewMode {
                do {
                    if next_frame.frame_index == viewModel.current_index {
                        switch self.frameViewMode {
                        case .original:
                            Task {
                                if let baseImage = try await next_frame.baseImage() {
                                    if next_frame.frame_index == viewModel.current_index {
                                        viewModel.current_frame_image = Image(nsImage: baseImage)
                                    }
                                }
                            }

                        case .processed:
                            Task {
                                if let baseImage = try await next_frame.baseOutputImage() {
                                    if next_frame.frame_index == viewModel.current_index {
                                        viewModel.current_frame_image = Image(nsImage: baseImage)
                                    }
                                }
                            }
                        case .testPainted:
                            Task {
                                if let baseImage = try await next_frame.baseTestPaintImage() {
                                    if next_frame.frame_index == viewModel.current_index {
                                        viewModel.current_frame_image = Image(nsImage: baseImage)
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    Log.e("error")
                }
            }

            if showOutliers {
                // try loading outliers if there aren't any present
                if viewModel.frames[next_frame.frame_index].outlierViews.count == 0 {
                    Task {
                        loading_outliers = true
                        let _ = try await next_frame.loadOutliers()
                        await viewModel.setOutlierGroups(forFrame: next_frame)
                        loading_outliers = false
                        viewModel.update()
                    }
                }
            }
        } else {
            Log.d("WTF for frame \(viewModel.current_index)")
            viewModel.update()
        }
    }
    
    
    func transition(toFrame new_frame_view: FrameView,
                    from old_frame: FrameAirplaneRemover?,
                    withScroll scroller: ScrollViewProxy? = nil)
    {
        //Log.d("transition from \(viewModel.currentFrame)")
        let start_time = Date().timeIntervalSinceReferenceDate

        viewModel.frames[viewModel.current_index].isCurrentFrame = false
        viewModel.frames[new_frame_view.frame_index].isCurrentFrame = true
        viewModel.current_index = new_frame_view.frame_index
        
        scroller?.scrollTo(viewModel.current_index)

        if !previewMode {
            viewModel.label_text = "frame \(new_frame_view.frame_index)"
        
            if let frame_to_save = old_frame {
                self.saveToFile(frame: frame_to_save) {
                    Log.d("completion closure called for frame \(frame_to_save.frame_index)")
                    Task {
                        Log.d("refreshing saved frame \(frame_to_save.frame_index)")
                        await viewModel.refresh(frame: frame_to_save)
                        refreshCurrentFrame()
                        Log.d("refreshing for frame \(frame_to_save.frame_index) complete")
                    }
                }
                // refresh the view model so we get the new images
                // XXX maybe don't let these go to file?

                // XXX this should happen after the save
                // also kick out processed and test paint images from image sequence
            }
        }
        
        refreshCurrentFrame()

        let end_time = Date().timeIntervalSinceReferenceDate
        Log.d("transition to frame \(new_frame_view.frame_index) took \(end_time - start_time) seconds")
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: ViewModel())
    }
}

