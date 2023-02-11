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
                        
                        Image(nsImage: outlierViewModel.image)
                        // offset from the center of parent view
                          .offset(x: CGFloat(outlier_center.x - frame_center_x),
                                  y: CGFloat(outlier_center.y - frame_center_y))
                          // tap gesture toggles paintability of the tapped group
                          .onTapGesture {
                              Log.d("t1")
//                              Task {
                              Log.d("t2")
                                  if let origShouldPaint = outlierViewModel.group.shouldPaint {
                                      // change the paintability of this outlier group
                                      // set it to user selected opposite previous value
                                      let reason = PaintReason.userSelected(!origShouldPaint.willPaint)
                                      Log.d("t3 reason \(reason)")
                                      outlierViewModel.group.shouldPaint(reason)
                                      
                                      // update the view model so it shows up on screen
                                      self.viewModel.update()
                                  } else {
                                      Log.e("WTF, not already set to paint??")
                                  }
  //                            }
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

        return ZStack {
            let frameView = viewModel.frames[frame_index]

            if viewModel.current_index == frame_index {            
                if frameView.thumbnail_image == nil {
                    Rectangle().foregroundColor(.orange)
                } else {
                    // highlight the selected frame
                    let opacity = viewModel.current_index == frame_index ? 0.4 : 0
                    frameView.thumbnail_image!
                      .overlay(
                        Rectangle()
                          .foregroundColor(.orange).opacity(opacity)
                      )
                }
            } else {
                if frameView.thumbnail_image == nil {
                    Rectangle()
                      .foregroundColor(bg_color)
                } else {
                    frameView.thumbnail_image!
                }
            }
            Text("\(frame_index)")

        }
          .frame(width: 80, height: 50)
          .onTapGesture {
        // XXX move this out 
        viewModel.label_text = "loading..."
        // XXX set loading image here
              // grab frame and try to show it
              let frame_view = viewModel.frames[frame_index]
              viewModel.current_index = frame_index

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
                    let count = viewModel.currentFrameView.outlierViews.count
                    if count > 0 {
                        Text("has \(count) outliers")
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
        viewModel.label_text = "loading..."
        // XXX set loading image here

                                let current_frame = viewModel.currentFrame
                                let new_frame_view = viewModel.previousFrame()
                                self.transition(toFrame: new_frame_view,
                                                from: current_frame,
                                                withScroll: scroller)
                            }) {
                                Text("Previous").font(.largeTitle)
                            }.buttonStyle(PlainButtonStyle())
                            //.keyboardShortcut(.rightArrow, modifiers: [])
                            .keyboardShortcut("a", modifiers: [])

                            // next button
                            Button(action: {
                                Log.d("next button pressed")
        // XXX move this out 
        viewModel.label_text = "loading..."
        // XXX set loading image here

                                Log.d("viewModel.current_index = \(viewModel.current_index)")
                                let current_frame = viewModel.currentFrame
                                let frame_view = viewModel.nextFrame()
                                
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
                        }
                        Button(action: {
                            Task {
                                await viewModel.currentFrame?.userSelectAllOutliers(toShouldPaint: true)
                                viewModel.update()
                            }
                        }) {
                            Text("Paint All").font(.largeTitle)
                        }.buttonStyle(PlainButtonStyle())
                         .keyboardShortcut("p", modifiers: [])
                        
                        Button(action: {
                            Task {
                                await viewModel.currentFrame?.userSelectAllOutliers(toShouldPaint: false)
                                viewModel.update()
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
                                  if let current_frame = viewModel.currentFrame {
                                      Task {
                                          do {
                                              if viewModel.frames[current_frame.frame_index].outlierViews.count == 0 {
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
                        Button(action: {
                            Task {
                                do {
                                    let start_time = Date().timeIntervalSinceReferenceDate
                                    await withThrowingTaskGroup(of: Void.self) { taskGroup in
                                        
                                        Log.d("foobar starting")
                                        // XXX try using a task group?
                                        for frameView in viewModel.frames {
                                            if let frame = frameView.frame {
                                                taskGroup.addTask(priority: .userInitiated) {
                                                    // XXX style the button during this flow?
                                                    try await frame.loadOutliers()
                                                }
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
                        }) {
                            Text("Load All Outliers").font(.largeTitle)
                        }.buttonStyle(PlainButtonStyle())
                        Button(action: {
                            Task {
                                for frameView in viewModel.frames {
                                    if let frame = frameView.frame,
                                       let frameSaveQueue = viewModel.frameSaveQueue
                                    {
                                        frameSaveQueue.saveNow(frame: frame)
                                    }
                                }
                            }
                        }) {
                            Text("Save All").font(.largeTitle)
                        }.buttonStyle(PlainButtonStyle())
                        
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
        Log.d("transition from \(viewModel.currentFrame)")
        
        viewModel.label_text = "frame \(new_frame_view.frame_index)"

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
                    await viewModel.setOutlierGroups(forFrame: next_frame)
                    viewModel.update()
                }
                scroller?.scrollTo(next_frame.frame_index)
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


