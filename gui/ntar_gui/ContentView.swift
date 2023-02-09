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

class FrameSaveQueue {

    class Pergatory {
        var timer: Timer
        let frame: FrameAirplaneRemover
        let block: @Sendable (Timer) -> Void
        let wait_time: TimeInterval = 60 // minimum time to wait in purgatory
        
        init(frame: FrameAirplaneRemover, block: @escaping @Sendable (Timer) -> Void) {
            self.frame = frame
            self.timer = Timer.scheduledTimer(withTimeInterval: wait_time,
                                              repeats: false, block: block)
            self.block = block
        }

        func retainLonger() {
            self.timer = Timer.scheduledTimer(withTimeInterval: wait_time,
                                              repeats: false, block: block)
        }
    }

    var pergatory: [Int: Pergatory] = [:] // both indexed by frame_index
    var saving: [Int: FrameAirplaneRemover] = [:]

    let finalProcessor: FinalProcessor
    
    init(_ finalProcessor: FinalProcessor) {
        self.finalProcessor = finalProcessor
    }
    
    func readyToSave(frame: FrameAirplaneRemover) {
        Log.w("frame \(frame.frame_index) entering pergatory")
        if let candidate = pergatory[frame.frame_index] {
            candidate.retainLonger()
        } else {
            let candidate = Pergatory(frame: frame) { timer in
                Log.w("pergatory has ended for frame \(frame.frame_index)")
                self.pergatory[frame.frame_index] = nil
                if let _ = self.saving[frame.frame_index] {
                    // go back to pergatory
                    self.readyToSave(frame: frame)
                } else {
                    // advance to saving state
                    Log.w("actually saving frame \(frame.frame_index)")
                    self.saving[frame.frame_index] = frame
                    Task {
                        await self.finalProcessor.final_queue.add(atIndex: frame.frame_index) {
                            Log.i("frame \(frame.frame_index) finishing")
                            try await frame.finish()
                            await MainActor.run {
                                self.saving[frame.frame_index] = nil
                            }
                            Log.i("frame \(frame.frame_index) finished")
                        }
                    }
                }
            }
        }
    }
}

class ViewModel: ObservableObject {
    var framesToCheck: FramesToCheck
    var eraser: NighttimeAirplaneRemover?
    var frameSaveQueue: FrameSaveQueue?
    var frame: FrameAirplaneRemover? {
        didSet {
            if let frame = frame {
                let new_frame_width = CGFloat(frame.width)
                let new_frame_height = CGFloat(frame.height)
                if frame_width != new_frame_width {
                    frame_width = new_frame_width
                }
                if frame_height != new_frame_height {
                    frame_height = new_frame_height
                }
                Log.w("INITIAL SIZE [\(frame_width), \(frame_height)]")
            } else {
                Log.e("NO INITIAL SIZE :(")
            }
        }
    }
    var outlierViews: [OutlierGroupView] = []
    var outlierCount: Int = 0
    var image: Image?
    var no_image_explaination_text: String = "Loading..."

    var frame_width: CGFloat = 300
    var frame_height: CGFloat = 300
    
    var label_text: String = "Started"

    var image_sequence_size: Int = 0
    
    init(framesToCheck: FramesToCheck) {
        self.framesToCheck = framesToCheck
        self.framesToCheck.viewModel = self
    }
    
    func update() async {
        if framesToCheck.isDone() {
            await MainActor.run {
                frame = nil
                outlierViews = []
                image = Image(systemName: "globe").resizable()
            }
        }
        if let frame = frame {
            let (outlierGroups, frame_width, frame_height) =
              await (frame.outlierGroups(), frame.width, frame.height)
            
            Log.i("we have \(outlierGroups.count) outlierGroups")
            await MainActor.run {
                outlierViews = []
            }
            for group in outlierGroups {
                if let cgImage = group.testImage() {
                    var size = CGSize()
                    size.width = CGFloat(cgImage.width)
                    size.height = CGFloat(cgImage.height)
                    let outlierImage = NSImage(cgImage: cgImage,
                                               size: size)

                    let groupView = OutlierGroupView(group: group,
                                                     name: group.name,
                                                     bounds: group.bounds,
                                                     image: outlierImage,
                                                     frame_width: frame_width,
                                                     frame_height: frame_height)
                    await MainActor.run {
                        outlierViews.append(groupView)
                    }
                } else {
                    Log.e("NO FUCKING IMAGE")
                }
            }
        }
        Task {
//            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run
            {                   // XXX this VVV isn't always right, it changes sometimes
                outlierCount = outlierViews.count
                self.objectWillChange.send()
            }
        }
    }
}

struct OutlierGroupView {
    let group: OutlierGroup
    let name: String
    let bounds: BoundingBox
    let image: NSImage
    let frame_width: Int
    let frame_height: Int
}

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
                ForEach(0 ..< viewModel.outlierViews.count, id: \.self) { idx in
                    if idx < viewModel.outlierViews.count {
                        let outlierViewModel = viewModel.outlierViews[idx]
                        
                        let frame_center_x = outlierViewModel.frame_width/2
                        let frame_center_y = outlierViewModel.frame_height/2
                        let outlier_center = outlierViewModel.bounds.center
                        
                        Image(nsImage: outlierViewModel.image)
                        // offset from the center of parent view
                          .offset(x: CGFloat(outlier_center.x - frame_center_x),
                                  y: CGFloat(outlier_center.y - frame_center_y))
                          // tap gesture toggles paintability of the tapped group
                          .onTapGesture {
                              Task {
                                  if let origShouldPaint = outlierViewModel.group.shouldPaint {
                                      // change the paintability of this outlier group
                                      // set it to user selected opposite previous value
                                      let reason = PaintReason.userSelected(!origShouldPaint.willPaint)
                                      outlierViewModel.group.shouldPaint(reason)
                                      
                                      // update the view model so it shows up on screen
                                      await self.viewModel.update()
                                  } else {
                                      Log.e("WTF, not already set to paint??")
                                  }
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
                               await viewModel.frame?.userSelectAllOutliers(toShouldPaint: selection_causes_painting,
                                                                            between: drag_start,
                                                                            and: end_location)
                               await viewModel.update()
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
        if let frame = viewModel.framesToCheck.frame(atIndex: frame_index) {
//            if frame.outlierGroupCount() > 0 {
//                bg_color = .red
//            } else {
                bg_color = .green
//            }
        }

        return ZStack {
            let frameView = viewModel.framesToCheck.frames[frame_index]

            if viewModel.framesToCheck.current_index == frame_index {            
                if frameView.preview_image == nil {
                    Rectangle().foregroundColor(.orange)
                } else {
                    // highlight the selected frame
                    let opacity = viewModel.framesToCheck.current_index == frame_index ? 0.4 : 0
                    frameView.preview_image!
                      .overlay(
                        Rectangle()
                          .foregroundColor(.orange).opacity(opacity)
                      )
                }
            } else {
                if frameView.preview_image == nil {
                    Rectangle()
                      .foregroundColor(bg_color)
                } else {
                    frameView.preview_image!
                }
            }
            Text("\(frame_index)")

        }
          .frame(width: 80, height: 50)
          .onTapGesture {
        // XXX move this out 
        viewModel.frame = nil
        viewModel.image = nil
        viewModel.label_text = "loading..."
        // XXX set loading image here
              // grab frame and try to show it
              let frame_view = viewModel.framesToCheck.frames[frame_index]
              viewModel.framesToCheck.current_index = frame_index

              let current_frame = viewModel.framesToCheck.currentFrame
              self.transition(toFrame: frame_view, from: current_frame)
          }

    }

    // used when advancing between frames
    func clearAndSave(frame frame_to_save: FrameAirplaneRemover) {
        if let frameSaveQueue = viewModel.frameSaveQueue {
            frameSaveQueue.readyToSave(frame: frame_to_save)
        } else {
            Log.e("FUCK")
            fatalError("SETUP WRONG")
        }
    }
    
    var body: some View {
        let scaling_anchor = UnitPoint(x: 0.75, y: 0.75)
        GeometryReader { top_geometry in
            VStack {
                if let frame_image = viewModel.image {
                    GeometryReader { geometry in
                        let min = geometry.size.height/viewModel.frame_height
                        let max = min < 1 ? 1 : min
                        ZoomableView(size: CGSize(width: viewModel.frame_width,
                                                  height: viewModel.frame_height),
                                     min: min,
                                     max: max,
                                     showsIndicators: true)
                        {
                            self.frameView(frame_image)
                        }
                    }
                } else {
                    ZStack {
                        Rectangle()
                          .foregroundColor(.yellow)
                        Text(viewModel.no_image_explaination_text)
                    }
                }
                HStack {
                    Text(viewModel.label_text)
                    if viewModel.outlierCount > 0 {
                        Text("has \(viewModel.outlierCount) outliers")
                    }
                }
                ScrollViewReader { scroller in
                VStack {
                    HStack {
                        if !running {
                            let action = {
                                running = true
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
                            // previous button
                            Button(action: {
        // XXX move this out 
        viewModel.frame = nil
        viewModel.image = nil
        viewModel.label_text = "loading..."
        // XXX set loading image here

                                let current_frame = viewModel.framesToCheck.currentFrame
                                let new_frame_view = viewModel.framesToCheck.previousFrame()
                                self.transition(toFrame: new_frame_view,
                                                from: current_frame,
                                                withScroll: scroller)
                            }) {
                                Text("Previous").font(.largeTitle)
                            }.buttonStyle(PlainButtonStyle())
                            //.keyboardShortcut(.rightArrow, modifiers: [])
                            .keyboardShortcut("a", modifiers: [])
                              .disabled(viewModel.frame == nil)

                            // next button
                            Button(action: {
                                Log.d("next button pressed")
        // XXX move this out 
        viewModel.frame = nil
        viewModel.image = nil
        viewModel.label_text = "loading..."
        // XXX set loading image here

                                Log.d("viewModel.framesToCheck.current_index = \(viewModel.framesToCheck.current_index)")
                                let current_frame = viewModel.framesToCheck.currentFrame
                                let frame_view = viewModel.framesToCheck.nextFrame()
                                
                                self.transition(toFrame: frame_view,
                                                from: current_frame,
                                                withScroll: scroller)
                            }) {
                                Text("Next").font(.largeTitle)
                            }
                            // XXX why doesn't .rightArrow work?
                            //.keyboardShortcut(KeyEquivalent.rightArrow, modifiers: [])
                            .keyboardShortcut("s", modifiers: [])
                            .buttonStyle(PlainButtonStyle())
                              .disabled(viewModel.frame == nil)
                        }
                        Button(action: {
                            Task {
                                await viewModel.frame?.userSelectAllOutliers(toShouldPaint: true)
                                await viewModel.update()
                            }
                        }) {
                            Text("Paint All").font(.largeTitle)
                        }.buttonStyle(PlainButtonStyle())
                         .keyboardShortcut("p", modifiers: [])
                        
                        Button(action: {
                            Task {
                                await viewModel.frame?.userSelectAllOutliers(toShouldPaint: false)
                                await viewModel.update()
                            }
                        }) {
                            Text("Clear All").font(.largeTitle)
                        }.buttonStyle(PlainButtonStyle())
                         .keyboardShortcut("c", modifiers: [])
                        Toggle("show outliers", isOn: $showOutliers)
                          .keyboardShortcut("o", modifiers: [])
                        Toggle("selection causes paint", isOn: $selection_causes_painting)
                          .keyboardShortcut("t", modifiers: []) // XXX find better modifier
                        Toggle("scrub mode", isOn: $scrubMode)
                          .keyboardShortcut("b", modifiers: [])
                          .onChange(of: scrubMode) { scrubbing in
                              if !scrubbing {
                                  if let current_frame = viewModel.framesToCheck.currentFrame {
                                      Task {
                                          do {
                                              if let baseImage = try await current_frame.baseImage() {
                                                  viewModel.image = Image(nsImage: baseImage)
                                                  await viewModel.update()
                                              }
                                          } catch {
                                              Log.e("error")
                                          }
                                      }
                                  }
                              }
                          }
                        Text("background")
                        Slider(value: $background_brightness, in: 0...100) { editing in
                            Log.d("editing \(editing) background_brightness \(background_brightness)")
                            background_color = Color(white: background_brightness/100)
                            viewModel.objectWillChange.send()
                        }
                        .frame(maxWidth: 100, maxHeight: 30)
                    }

                    // the filmstrip at the bottom
                        ScrollView(.horizontal) {
                            HStack(spacing: 5) {
                                ForEach(0..<viewModel.image_sequence_size, id: \.self) { frame_index in
                                    self.filmStripView(forFrame: frame_index)
                                    
                                }
                            }
                        }.frame(maxWidth: .infinity, maxHeight: 50)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
              .padding()
              .background(background_color)
        }
    }

    func transition(toFrame new_frame_view: FrameView,
                    from old_frame: FrameAirplaneRemover?,
                    withScroll scroller: ScrollViewProxy? = nil)
    {
        Log.d("pergatory transition from \(viewModel.frame)")
        
        viewModel.label_text = "frame \(new_frame_view.frame_index)"

        if let frame_to_save = old_frame {
            self.clearAndSave(frame: frame_to_save)
        }
        
        if let next_frame = new_frame_view.frame {
            viewModel.frame = next_frame

            // stick the scrub image in there first if we have it
            if let scrub_image = new_frame_view.scrub_image {
                viewModel.image = scrub_image.resizable()
                Task {
                    await viewModel.update()
                }
            }
            if !scrubMode {
                // get the full resolution image async from the frame
                Task {
                    do {
                        if let baseImage = try await next_frame.baseImage() {
                            viewModel.image = Image(nsImage: baseImage)
                            await viewModel.update()
                        }
                    } catch {
                        Log.e("error")
                    }
                }
            }
            if !scrubMode {
                scroller?.scrollTo(next_frame.frame_index)
            }
        } else {
            viewModel.frame = nil
            viewModel.outlierViews = []
            //viewModel.image = Image(systemName: "person").resizable()
            Task { await viewModel.update() }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: ViewModel(framesToCheck: FramesToCheck()))
    }
}


