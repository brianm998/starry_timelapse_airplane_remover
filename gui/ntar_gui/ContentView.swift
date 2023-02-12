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

// the overall level of the app
struct ContentView: View {
    @ObservedObject var viewModel: ViewModel
    @State private var showOutliers = true
    @State private var scrubMode = true
    @State private var selection_causes_painting = true
    @State private var running = false
    @State private var drag_start: CGPoint?
    @State private var drag_end: CGPoint?
    @State private var isDragging = false
    @State private var background_brightness: Double = 0.33
    @State private var background_color: Color = .gray

    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }
    
    // this is the frame with outliers on top of it
    func frameView( _ image: Image) -> some View {
        return ZStack {
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
                    if frameView.thumbnail_image == nil {
                        Rectangle().foregroundColor(.orange)
                          .frame(maxWidth: CGFloat((viewModel.config?.thumbnail_width ?? 80)),
                                 maxHeight: CGFloat((viewModel.config?.thumbnail_height ?? 50)))
                    } else {
                        frameView.thumbnail_image!
                    }
                } else {
                    if frameView.thumbnail_image == nil {
                        Rectangle()
                          .foregroundColor(bg_color)
                          .frame(maxWidth: CGFloat((viewModel.config?.thumbnail_width ?? 80)),
                                 maxHeight: CGFloat((viewModel.config?.thumbnail_height ?? 50)))
                    } else {
                        frameView.thumbnail_image!
                    }
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
    func saveToFile(frame frame_to_save: FrameAirplaneRemover) {
        if let frameSaveQueue = viewModel.frameSaveQueue {
            frameSaveQueue.readyToSave(frame: frame_to_save)
        } else {
            Log.e("FUCK")
            fatalError("SETUP WRONG")
        }
    }

    let button_size: CGFloat = 50
    
    var body: some View {
        let scaling_anchor = UnitPoint(x: 0.75, y: 0.75)
        GeometryReader { top_geometry in
            VStack {
                if let frame_image = viewModel.currentFrameView.image {
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
                    ZStack {
                        Rectangle()
                          .foregroundColor(.yellow)
                          .frame(maxWidth: viewModel.frame_width, maxHeight: viewModel.frame_height)
                        Text(viewModel.no_image_explaination_text)
                    }
                }
                HStack {
                    Text(viewModel.label_text).font(.largeTitle)
                    let count = viewModel.currentFrameView.outlierViews.count
                    if count > 0 {
                        Text("has \(count) outliers").font(.largeTitle)
                    }
                }
                ScrollViewReader { scroller in
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
                                
                                if viewModel.initial_load_in_progress {
                                    ProgressView()
                                      .scaleEffect(1, anchor: .center)
                                      .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                                    Spacer()
                                      .frame(maxWidth: 50)
                                }
                                
                                playButtons(scroller)
                            }
                            paintAllButton()
                            clearAllButton()

                            toggleViews()
                            
                            Text("background")
                            Slider(value: $background_brightness, in: 0...100) { editing in
                                Log.d("editing \(editing) background_brightness \(background_brightness)")
                                background_color = Color(white: background_brightness/100)
                                viewModel.objectWillChange.send()
                            }
                              .frame(maxWidth: 100, maxHeight: 30)
                            
                            //load all outlier button
                            //loadAllOutliersButton()
                            
                            saveAllButton()
                            
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

    func clearAllButton() -> some View {
        Button(action: {
            Task {
                await viewModel.currentFrame?.userSelectAllOutliers(toShouldPaint: false)
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

    func saveAllButton() -> some View {
        let action: () -> Void = {
            Task {
                for frameView in viewModel.frames {
                    if let frame = frameView.frame,
                       let frameSaveQueue = viewModel.frameSaveQueue
                    {
                        frameSaveQueue.saveNow(frame: frame)
                    }
                }
            }
        }
        
        return Button(action: action) {
            Text("Save All").font(.largeTitle)
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
                        Log.d("foobar starting")
                        for frameView in viewModel.frames {
                            if current_running < max_concurrent {
                                if let frame = frameView.frame {
                                    current_running += 1
                                    taskGroup.addTask(priority: .userInitiated) {
                                        // XXX style the button during this flow?
                                        try await frame.loadOutliers()
                                    }
                                }
                            } else {
                                try await taskGroup.next()
                                current_running -= 1
                            }
                        }
                        do {
                            try await taskGroup.waitForAll()
                        } catch {
                            Log.e("\(error)")
                        }
                        
                        let end_time = Date().timeIntervalSinceReferenceDate
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
    func playButtons(_ scroller: ScrollViewProxy) -> some View {

        let start_shortcut_key: KeyEquivalent = "b"
        let fast_previous_shortut_key: KeyEquivalent = "z"
        let fast_skip_amount = 20 // XXX make this configurable
        
        let previous_shortut_key: KeyEquivalent = .leftArrow

        let fast_next_shortcut_key: KeyEquivalent = "x"
        let end_button_shortcut_key: KeyEquivalent = "e"
        
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
                                withScroll: scrubMode ? nil : scroller)
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
                                withScroll: scrubMode ? nil : scroller)
            }

            // play/pause button
            button(named: "play.fill", // pause.fill
                   shortcutKey: previous_shortut_key,
                   color: .yellow,
                   toolTip: """
                     Play / Pause
                     """)
            {
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
                                withScroll: scrubMode ? nil : scroller)
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
                                withScroll: scrubMode ? nil : scroller)
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

    func toggleViews() -> some View {
        VStack(alignment: .leading) {
            Toggle("show outliers", isOn: $showOutliers)
              .keyboardShortcut("o", modifiers: [])
            Toggle("selection causes paint", isOn: $selection_causes_painting)
              .keyboardShortcut("t", modifiers: []) // XXX find better modifier
            Toggle("scrub mode", isOn: $scrubMode)
              .keyboardShortcut("b", modifiers: [])
              .onChange(of: scrubMode) { scrubbing in
                  if !scrubbing {
                      if let current_frame = viewModel.currentFrame {
                          Task {
                              do {
                                  if viewModel.frames[current_frame.frame_index].outlierViews.count == 0 {
                                      // only set them if they're not present
                                      let _ = try await current_frame.loadOutliers()
                                      await viewModel.setOutlierGroups(forFrame: current_frame)
                                  }
                                  if let baseImage = try await current_frame.baseImage() {
                                      viewModel.currentFrameView.image = Image(nsImage: baseImage)
                                      viewModel.update()
                                  }
                              } catch {
                                  Log.e("error")
                              }
                          }
                      } else {
                          Log.i("not scrubbing with NO frame")
                      }
                  }
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
    
    func transition(toFrame new_frame_view: FrameView,
                    from old_frame: FrameAirplaneRemover?,
                    withScroll scroller: ScrollViewProxy? = nil)
    {
        Log.d("transition from \(viewModel.currentFrame)")
        
        viewModel.label_text = "frame \(new_frame_view.frame_index)"
        viewModel.current_index = new_frame_view.frame_index
        scroller?.scrollTo(viewModel.current_index)
        
        if !scrubMode {
            if let frame_to_save = old_frame {
                self.saveToFile(frame: frame_to_save)
            }
        }
        
        if let next_frame = new_frame_view.frame {

            // stick the scrub image in there first if we have it
            if let preview_image = new_frame_view.preview_image {
                viewModel.currentFrameView.image = preview_image.resizable()
                viewModel.update()
            }
            if !scrubMode {
                // get the full resolution image async from the frame
                Task {
                    do {
                        if let baseImage = try await next_frame.baseImage() {
                            viewModel.currentFrameView.image = Image(nsImage: baseImage)
                            viewModel.update()
                        }
                    } catch {
                        Log.e("error")
                    }
                }
            }
            if !scrubMode {
                Task {
                    if viewModel.frames[next_frame.frame_index].outlierViews.count == 0 {
                        let _ = try await next_frame.loadOutliers()
                        await viewModel.setOutlierGroups(forFrame: next_frame)
                        viewModel.update()
                    }
                }
            }
        } else {
            viewModel.update()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: ViewModel())
    }
}

