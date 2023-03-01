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

struct SettingsSheetView: View {
    @Binding var isVisible: Bool
    @Binding var fast_skip_amount: Int
    @Binding var video_playback_framerate: Int
    @Binding var skipEmpties: Bool
    
    var body: some View {
        VStack {
            Spacer()
            Text("Settings")
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading) {
                    Text(skipEmpties ?
                           "Fast Forward and Reverse skip empties" :
                           "Fast Forward and Reverse move by \(fast_skip_amount) frames")
                    
                    Toggle(skipEmpties ? "change to # of frames" : "change to skip empties",
                           isOn: $skipEmpties)

                    if !skipEmpties {
                        Picker("Fast Skip", selection: $fast_skip_amount) {
                            ForEach(0 ..< 51) {
                                Text("\($0) frames")
                            }
                        }.frame(maxWidth: 200)
                    }
                    let frame_rates = [5, 10, 15, 20, 25, 30]
                    Picker("Frame Rate", selection: $video_playback_framerate) {
                        ForEach(frame_rates, id: \.self) {
                            Text("\($0) fps")
                        }
                    }.frame(maxWidth: 200)
                }
                Spacer()
            }
            
            Button("Done") {
                self.isVisible = false
            }
            Spacer()
        }
        //.frame(width: 300, height: 150)
    }
}

struct MassivePaintSheetView: View {
    @Binding var isVisible: Bool
    @ObservedObject var viewModel: ViewModel
    var closure: (Bool, Int, Int) -> Void

    @State var start_index: Int = 0
    @State var end_index: Int = 1   // XXX 1
    @State var should_paint = false

    init(isVisible: Binding<Bool>,
         viewModel: ViewModel,
         closure: @escaping (Bool, Int, Int) -> Void)
    {
        self._isVisible = isVisible
        self.closure = closure
        self.viewModel = viewModel
    }
    
    var body: some View {
        HStack {

            Spacer()
            VStack {
                Spacer()
                Text((should_paint ? "Paint" : "Clear") + " \(end_index-start_index) frames from")
                Spacer()
                Picker("start frame", selection: $start_index) {
                    ForEach(0 ..< viewModel.frames.count, id: \.self) {
                        Text("frame \($0)")
                    }
                }
                Spacer()
                Picker("to end frame", selection: $end_index) {
                    ForEach(0 ..< viewModel.frames.count, id: \.self) {
                        Text("frame \($0)")
                    }
                }
                Toggle("should paint", isOn: $should_paint)

                HStack {
                    Button("Cancel") {
                        self.isVisible = false
                    }
                    
                    Button(should_paint ? "Paint All" : "Clear All") {
                        self.isVisible = false
                        closure(should_paint, start_index, end_index)
                    }
                }
                Spacer()
            }
            Spacer()
        }
    }
}

// the overall level of the app
struct ContentView: View {
    @ObservedObject var viewModel: ViewModel
    @State private var showOutliers = false
    
    // enum for how we show each frame
    @State private var frameViewMode = FrameViewMode.processed
    
    // should we show full resolution images on the main frame?
    // faster low res previews otherwise
    @State private var showFullResolution = false
    
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
    @State private var updating_frame_batch = false

    @State private var video_playback_framerate = 10
    @State private var video_playing = false

    @State private var skipEmpties = false
    // if not skip empties, fast forward and reverse do a set number of frames
    @State private var fast_skip_amount = 20

    @State private var settings_sheet_showing = false
    @State private var paint_sheet_showing = false
    
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        //let scaling_anchor = UnitPoint(x: 0.75, y: 0.75)

        if !running {
            initialView()
        } else {
        
        GeometryReader { top_geometry in
            ScrollViewReader { scroller in
                VStack {
                    let should_show_progress =
                      viewModel.initial_load_in_progress ||
                      loading_outliers                   ||
                      loading_all_outliers               || 
                      rendering_current_frame            ||
                      updating_frame_batch               ||
                      rendering_all_frames
                    
                    ZStack {
                        
                        currentFrameView()
                         .frame(maxWidth: .infinity, alignment: .center)
                      .overlay(
                        ProgressView()
                          .scaleEffect(8, anchor: .center) // this is blocky scaled up 
                          .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                          .frame(maxWidth: 200, maxHeight: 200)
                          .opacity(should_show_progress ? 0.8 : 0)
                      )
                    }.overlay(
                          VStack {
                            paintAllButton()
                              .frame(maxWidth: .infinity, alignment: .bottomTrailing)
                            clearAllButton()
                              .frame(maxWidth: .infinity, alignment: .bottomTrailing)
                            loadAllOutliersButton()
                              .frame(maxWidth: .infinity, alignment: .bottomTrailing)
                            renderCurrentFrameButton()
                              .frame(maxWidth: .infinity, alignment: .bottomTrailing)
                            renderAllFramesButton()
                              .frame(maxWidth: .infinity, alignment: .bottomTrailing)
                          }//.background(.green)
//                            .frame(maxWidth: .infinity, alignment: .center)
//                            .frame(maxWidth: .infinity, alignment: .bottomTrailing)
//                      }.background(.red)
//                        .frame(maxWidth: .infinity, alignment: .bottomTrailing)
                             , alignment: .bottom)

                    /*
                    if showFullResolution {
                        HStack {
                            Text(viewModel.label_text).font(.largeTitle)
                            let count = viewModel.currentFrameView.outlierViews.count
                            if count > 0 {
                                Text("has \(count) outliers").font(.largeTitle)
                            }
                        }
                    }*/
                    VStack {
                        HStack {

                            ZStack {
                                
                                    videoPlaybackButtons(scroller) // XXX not really centered
                                      .frame(maxWidth: .infinity, alignment: .center)
                                
                                // rectangle.split.3x1
                                // 
                                    HStack {
                                        
                                        let paint_action = {
                                            Log.d("PAINT")
                                            paint_sheet_showing = !paint_sheet_showing
                                        }
                                        Button(action: paint_action) {
                                            buttonImage("square.stack.3d.forward.dottedline", size: 44)
                                            
                                        }
                                          .buttonStyle(PlainButtonStyle())           
                                          .frame(alignment: .trailing)
                                        
                                        
                                        let gear_action = {
                                            Log.d("GEAR")
                                            settings_sheet_showing = !settings_sheet_showing
                                        }
                                        Button(action: gear_action) {
                                            buttonImage("gearshape.fill", size: 44)
                                            
                                        }
                                          .buttonStyle(PlainButtonStyle())           
                                          .frame(alignment: .trailing)
                                        
                                        /*
                                         if running {
                                         Menu("FUCKING MENU"/*buttonImage("gearshape.fill", size: 30)*/) {
                                         
                                         }
                                         }*/
                                        toggleViews()
                                    }
                                      .frame(maxWidth: .infinity, alignment: .trailing)
                                      .sheet(isPresented: $settings_sheet_showing) {
                                          SettingsSheetView(isVisible: self.$settings_sheet_showing,
                                                            fast_skip_amount: self.$fast_skip_amount,
                                                            video_playback_framerate: self.$video_playback_framerate,
                                                            skipEmpties: self.$skipEmpties)
                                      }
                                      .sheet(isPresented: $paint_sheet_showing) {
                                          MassivePaintSheetView(isVisible: self.$paint_sheet_showing,
                                                                viewModel: viewModel)
                                          { should_paint, start_index, end_index in
                                              
                                              updating_frame_batch = true
                                              
                                              for idx in start_index ... end_index {
                                                  // XXX use a task group?
                                                  setAllFrameOutliers(in: viewModel.frames[idx], to: should_paint)
                                              }
                                              // XXX 
                                              updating_frame_batch = false
                                              
                                              // XXX iterate through start->end
                                              // setFrameOutliers()
                                              Log.d("should_paint \(should_paint), start_index \(start_index), end_index \(end_index)")
                                          }
                                      }
                                }//.background(.green)
                                /*
                                 VStack {
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
                            }
                                */
                            
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
                            
                            }
                        
                        Spacer().frame(maxHeight: 30)
                        // the filmstrip at the bottom
                        filmstrip()
                          .frame(maxWidth: .infinity, alignment: .bottom)
                        Spacer().frame(maxHeight: 10, alignment: .bottom)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
              .padding()
              .background(background_color)
        }
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
            // the main image shown
            image

            if showOutliers {
                let current_frame_view = viewModel.currentFrameView
                let outlierViews = current_frame_view.outlierViews
                ForEach(0 ..< outlierViews.count, id: \.self) { idx in
                    if idx < outlierViews.count {
                        let outlierViewModel = outlierViews[idx]
                        
                        let frame_center_x = outlierViewModel.frame_width/2
                        let frame_center_y = outlierViewModel.frame_height/2
                        let outlier_center = outlierViewModel.bounds.center

                        let will_paint = outlierViewModel.group.shouldPaint == nil ? false :
                          outlierViewModel.group.shouldPaint!.willPaint

                        let paint_color: Color = will_paint ? .red : .green
                        
                        Image(nsImage: outlierViewModel.image)
                          .renderingMode(.template) // makes this VV color work
                          .foregroundColor(paint_color)
                          .offset(x: CGFloat(outlier_center.x - frame_center_x),
                                  y: CGFloat(outlier_center.y - frame_center_y))
                          // tap gesture toggles paintability of the tapped group
                          .onTapGesture {
                              if let origShouldPaint = outlierViewModel.group.shouldPaint {
                                  // change the paintability of this outlier group
                                  // set it to user selected opposite previous value
                                  let reason = PaintReason.userSelected(!origShouldPaint.willPaint)

                                  // update the view model to show the change quickly
                                  outlierViewModel.group.shouldPaint = reason
                                  self.viewModel.update()
                                  
                                  Task {
                                      if let frame = viewModel.currentFrame,
                                         let outlier_groups = await frame.outlier_groups,
                                         let groups = outlier_groups.groups,
                                         let outlier_group = groups[outlierViewModel.group.name]
                                      {
                                          // update the actor in the background
                                          await outlier_group.shouldPaint(reason)
                                          self.viewModel.update()
                                      } else {
                                          Log.e("HOLY FUCK")
                                      }
                                  }
                                  // update the view model so it shows up on screen
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
                           
                           let frameView = viewModel.currentFrameView
                           frameView.userSelectAllOutliers(toShouldPaint: selection_causes_painting,
                                                           between: drag_start,
                                                           and: end_location)

                           if let frame = frameView.frame {
                               Task {
                                   // is view layer updated? (NO)
                                   await frame.userSelectAllOutliers(toShouldPaint: selection_causes_painting,
                                                                     between: drag_start,
                                                                     and: end_location)
                                   refreshCurrentFrame()
                                   viewModel.update()
                               }
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
    
    func setAllCurrentFrameOutliers(to shouldPaint: Bool,
                                    renderImmediately: Bool = true)
    {
        let current_frame_view = viewModel.currentFrameView
        setAllFrameOutliers(in: current_frame_view,
                            to: shouldPaint,
                            renderImmediately: renderImmediately)
    }
    
    func setAllFrameOutliers(in frame_view: FrameView,
                             to shouldPaint: Bool,
                             renderImmediately: Bool = true)
    {
        Log.d("setAllFrameOutliers in frame \(frame_view.frame_index) to should paint \(shouldPaint)")
        let reason = PaintReason.userSelected(shouldPaint)
        
        // update the view model first
        let outlierViews = frame_view.outlierViews
        outlierViews.forEach { outlierView in
            outlierView.group.shouldPaint = reason
        }

        if let frame = frame_view.frame {
            // update the real actor in the background
            Task {
                await frame.userSelectAllOutliers(toShouldPaint: shouldPaint)

                if renderImmediately {
                    // XXX make render here an option in settings
                    await render(frame: frame) {
                        Task {
                            await viewModel.refresh(frame: frame)
                            if frame.frame_index == viewModel.current_index {
                                refreshCurrentFrame() // XXX not always current
                            }
                            viewModel.update()
                        }
                    }
                } else {
                    if frame.frame_index == viewModel.current_index {
                        refreshCurrentFrame() // XXX not always current
                    }
                    viewModel.update()
                }
            }
        } else {
            Log.w("frame \(frame_view.frame_index) has no frame")
        }
    }
    
    func paintAllButton() -> some View {
        Button(action: {
                   setAllCurrentFrameOutliers(to: true, renderImmediately: false)
        }) {
            Text("Paint All").font(.largeTitle)
        }
        .buttonStyle(ShrinkingButton())
        .keyboardShortcut("p", modifiers: [])
    }
    
    func clearAllButton() -> some View {
        Button(action: {
            setAllCurrentFrameOutliers(to: false, renderImmediately: false)
        }) {
            Text("Clear All").font(.largeTitle)
        }
          .buttonStyle(ShrinkingButton())
          .keyboardShortcut("c", modifiers: [])
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
        }.buttonStyle(ShrinkingButton())
    }

    func renderCurrentFrame(_ closure: (() -> Void)? = nil) async {
        if let frame = viewModel.currentFrame {
            await render(frame: frame, closure: closure)
        }
    }
    
    func render(frame: FrameAirplaneRemover, closure: (() -> Void)? = nil) async {
        if let frameSaveQueue = viewModel.frameSaveQueue
        {
            self.rendering_current_frame = true // XXX might not be right anymore
            frameSaveQueue.saveNow(frame: frame) {
                await viewModel.refresh(frame: frame)
                refreshCurrentFrame()
                self.rendering_current_frame = false
                closure?()
            }
        }
    }
    
    func renderCurrentFrameButton() -> some View {
        let action: () -> Void = {
            Task { await self.renderCurrentFrame() }
        }
        
        return Button(action: action) {
            Text("Render This Frame").font(.largeTitle)
        }.buttonStyle(ShrinkingButton())
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
        }.buttonStyle(ShrinkingButton())
    }
    
    // an HStack of buttons to advance backwards and fowards through the sequence
    func videoPlaybackButtons(_ scroller: ScrollViewProxy) -> some View {

        // XXX these should really use modifiers but those don't work :(
        let start_shortcut_key: KeyEquivalent = "b" // make this bottom arror
        let fast_previous_shortut_key: KeyEquivalent = "z"
        let previous_shortut_key: KeyEquivalent = .leftArrow
        let fast_next_shortcut_key: KeyEquivalent = "x"
        let end_button_shortcut_key: KeyEquivalent = "e" // make this top arror

        let button_color = Color(white: 202/256)
        
        return HStack {
            // start button
            button(named: "backward.end.fill",
                   shortcutKey: start_shortcut_key,
                   color: button_color,
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
                   color: button_color,
                   toolTip: """
                     back \(fast_skip_amount) frames
                     (keyboard shortcut '\(fast_previous_shortut_key.character)')
                     """)
            {
                if skipEmpties {
                    if let current_frame = viewModel.currentFrame {
                        self.transitionUntilNotEmpty(from: current_frame,
                                                     forwards: false,
                                                     withScroll: scroller)
                    }
                } else {
                    self.transition(numberOfFrames: -fast_skip_amount,
                                                      withScroll: scroller)
                }
            }
            
            // previous button
            button(named: "backward.frame.fill",
                   shortcutKey: previous_shortut_key,
                   color: button_color,
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
                   color: button_color,
                   size: 40,
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
                   color: button_color,
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
                   color: button_color,
                   toolTip: """
                     forward \(fast_skip_amount) frames
                     (keyboard shortcut '\(fast_next_shortcut_key.character)')
                     """)
            {
                if skipEmpties {
                    if let current_frame = viewModel.currentFrame {
                        self.transitionUntilNotEmpty(from: current_frame,
                                                     forwards: true,
                                                     withScroll: scroller)
                    }
                } else {
                    self.transition(numberOfFrames: fast_skip_amount,
                                    withScroll: scroller)
                }
            }
            
            
            // end button
            button(named: "forward.end.fill",
                   shortcutKey: end_button_shortcut_key,
                   color: button_color,
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

                // play each frame of the video in sequence
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
                    scroller.scrollTo(viewModel.current_index, anchor: .center)
                    video_playing = false
                }
            }
        } else {
            self.showOutliers = true // XXX maybe track previous state before setting it off at start of video play?
            video_play_timer?.invalidate()
            Log.d("not playing")
            // scroller usage here
            viewModel.current_index = current_video_frame
            scroller.scrollTo(viewModel.current_index, anchor: .center)
        }
    }
    
    func toggleViews() -> some View {
        HStack() {
            VStack(alignment: .leading) {
                Toggle("modify outliers", isOn: $showOutliers)
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
                Picker("show", selection: $frameViewMode) {
                    // XXX expand this to not use allCases, but only those that we have files for
                    // i.e. don't show test-paint when the sequence wasn't test painted
                    ForEach(FrameViewMode.allCases, id: \.self) { value in
                        Text(value.localizedName).tag(value)
                    }
                }
                  .frame(maxWidth: 180)
                  .onChange(of: frameViewMode) { pick in
                      Log.d("pick \(pick)")
                      refreshCurrentFrame()
                  }
                
                Toggle("full resolution", isOn: $showFullResolution)
                  .onChange(of: showFullResolution) { mode_on in
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
                          showFullResolution = false

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

    func initialView() -> some View {
        VStack {
            Text("Welcome to the Nighttime Timelapse Airplane Remover")
              .font(.largeTitle)
            Spacer()
              .frame(maxHeight: 200)
            Text("Choose an option to get started")
            
            HStack {
                // XXX this one will go away
                let run = {
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
                Button(action: run) {
                    Text("START").font(.largeTitle)
                }.buttonStyle(ShrinkingButton())
                // XXX this one will go away

                let loadConfig = {
                    Log.d("load config")

                    let openPanel = NSOpenPanel()
                    openPanel.allowedFileTypes = ["json"]
                    openPanel.allowsMultipleSelection = false
                    openPanel.canChooseDirectories = false
                    openPanel.canChooseFiles = true
                    let response = openPanel.runModal()
                    if response == .OK {
                        let returnedUrl = openPanel.url
                        Log.d("returnedUrl \(returnedUrl)")
                    }
                }
                
                Button(action: loadConfig) {
                    Text("Load Config").font(.largeTitle)
                }.buttonStyle(ShrinkingButton())
                  .help("Load a json config file from a previous run of ntar")

                let loadImageSequence = {
                    Log.d("load image sequence")
                    let openPanel = NSOpenPanel()
                    //openPanel.allowedFileTypes = ["json"]
                    openPanel.allowsMultipleSelection = false
                    openPanel.canChooseDirectories = true
                    openPanel.canChooseFiles = false
                    let response = openPanel.runModal()
                    if response == .OK {
                        let returnedUrl = openPanel.url
                        Log.d("returnedUrl \(returnedUrl)")
                    }
                }
                
                Button(action: loadImageSequence) {
                    Text("Load Image Sequence").font(.largeTitle)
                }.buttonStyle(ShrinkingButton())
                  .help("Load an image sequence yet to be processed by ntar")

                let loadRecent = {
                    Log.d("load image sequence")

                    // XXX implement a recent list, probably just previous json config files
                }
                
                Button(action: loadRecent) {
                    Text("Open Recent").font(.largeTitle)
                }.buttonStyle(ShrinkingButton())
                  .help("open a recently processed sequence")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    func buttonImage(_ name: String, size: CGFloat) -> some View {
        return Image(systemName: name)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: size,
                 maxHeight: size,
                 alignment: .center)
    }
    
    func button(named button_name: String,
                shortcutKey: KeyEquivalent,
                modifiers: EventModifiers = [],
                color: Color,
                size: CGFloat = 30,
                toolTip: String,
                action: @escaping () -> Void) -> some View
    {
        //Log.d("button \(button_name) using modifiers \(modifiers)")
        return ZStack {
            Button("", action: action)
              .opacity(0)
              .keyboardShortcut(shortcutKey, modifiers: modifiers)
            
            Button(action: action) {
                buttonImage(button_name, size: size)
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
    
    func transitionUntilNotEmpty(from frame: FrameAirplaneRemover,
                                 forwards: Bool,
                                 currentIndex: Int? = nil,
                                 withScroll scroller: ScrollViewProxy? = nil)
    {
        var frame_index: Int = 0
        if let currentIndex = currentIndex {
            frame_index = currentIndex
        } else {
            frame_index = frame.frame_index
        }
        
        if (!forwards && frame_index == 0) ||  
           (forwards && frame_index >= viewModel.frames.count - 1)
        {
            if frame_index != frame.frame_index {
                self.transition(toFrame: viewModel.frames[frame_index],
                                from: frame,
                                withScroll: scroller)
            }
            return
        }
        
        var next_frame_index = 0
        if forwards {
            next_frame_index = frame_index + 1
        } else {
            next_frame_index = frame_index - 1
        }
        let next_frame_view = viewModel.frames[next_frame_index]
        if next_frame_view.outlierViews.count == 0 {
            // skip this one
            self.transitionUntilNotEmpty(from: frame,
                                         forwards: forwards,
                                         currentIndex: next_frame_index,
                                         withScroll: scroller)
        } else {
            self.transition(toFrame: next_frame_view,
                            from: frame,
                            withScroll: scroller)
        }
    }
    
    func refreshCurrentFrame() {
        // XXX maybe don't wait for frame?
        Log.d("refreshCurrentFrame \(viewModel.current_index)")
        let new_frame_view = viewModel.frames[viewModel.current_index]
        if let next_frame = new_frame_view.frame {

            // usually stick the preview image in there first if we have it
            var show_preview = true

            /*
            Log.d("showFullResolution \(showFullResolution)")
            Log.d("viewModel.current_frame_image_index \(viewModel.current_frame_image_index)")
            Log.d("new_frame_view.frame_index \(new_frame_view.frame_index)")
            Log.d("viewModel.current_frame_image_view_mode \(viewModel.current_frame_image_view_mode)")
            Log.d("self.frameViewMode \(self.frameViewMode)")
            Log.d("viewModel.current_frame_image_was_preview \(viewModel.current_frame_image_was_preview)")
             */

            if showFullResolution &&
               viewModel.current_frame_image_index == new_frame_view.frame_index &&
               viewModel.current_frame_image_view_mode == self.frameViewMode &&
               !viewModel.current_frame_image_was_preview
            {
                // showing the preview in this case causes flickering
                show_preview = false
            }
                 
            if show_preview {
                viewModel.current_frame_image_index = new_frame_view.frame_index
                viewModel.current_frame_image_was_preview = true
                viewModel.current_frame_image_view_mode = self.frameViewMode

                switch self.frameViewMode {
                case .original: // XXX do we need add .resizable() here, and is it slowing us down?
                    viewModel.current_frame_image = new_frame_view.preview_image.resizable()
                case .processed:
                    viewModel.current_frame_image = new_frame_view.processed_preview_image.resizable()
                case .testPainted:
                    viewModel.current_frame_image = new_frame_view.test_paint_preview_image.resizable()
                }
            }
            if showFullResolution {
                if next_frame.frame_index == viewModel.current_index {
                    Task {
                        do {
                            viewModel.current_frame_image_index = new_frame_view.frame_index
                            viewModel.current_frame_image_was_preview = false
                            viewModel.current_frame_image_view_mode = self.frameViewMode
                            
                            switch self.frameViewMode {
                            case .original:
                                if let baseImage = try await next_frame.baseImage() {
                                    if next_frame.frame_index == viewModel.current_index {
                                        viewModel.current_frame_image = Image(nsImage: baseImage)
                                    }
                                }
                                
                            case .processed:
                                if let baseImage = try await next_frame.baseOutputImage() {
                                    if next_frame.frame_index == viewModel.current_index {
                                        viewModel.current_frame_image = Image(nsImage: baseImage)
                                    }
                                }
                                
                            case .testPainted:
                                if let baseImage = try await next_frame.baseTestPaintImage() {
                                    if next_frame.frame_index == viewModel.current_index {
                                        viewModel.current_frame_image = Image(nsImage: baseImage)
                                    }
                                }
                            }
                        } catch {
                            Log.e("error")
                        }
                    }
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
        
        if let scroller = scroller {
            scroller.scrollTo(viewModel.current_index, anchor: .center)

            viewModel.label_text = "frame \(new_frame_view.frame_index)"

            // only save frame when we are also scrolling (i.e. not scrubbing)
            if let frame_to_save = old_frame {
                self.saveToFile(frame: frame_to_save) {
                    Log.d("completion closure called for frame \(frame_to_save.frame_index)")
                    Task {
                        Log.d("refreshing saved frame \(frame_to_save.frame_index)")
                        await viewModel.refresh(frame: frame_to_save)
                        Log.d("refreshing for frame \(frame_to_save.frame_index) complete")
                    }
                }
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

struct ShrinkingButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(Color(red: 75/256, green: 80/256, blue: 147/256))
            .foregroundColor(.white)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.15),
                       value: configuration.isPressed)
    }
}
