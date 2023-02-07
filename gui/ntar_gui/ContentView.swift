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

class ViewModel: ObservableObject {
    var framesToCheck: FramesToCheck
    var eraser: NighttimeAirplaneRemover?
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

    var frame_width: CGFloat = 300
    var frame_height: CGFloat = 300
    
    // frame states as individual values
    var number_unprocessed: Int = 0
    var number_loadingImages: Int = 0
    var number_detectingOutliers: Int = 0
    var number_readyForInterFrameProcessing: Int = 0
    var number_interFrameProcessing: Int = 0
    var number_outlierProcessingComplete: Int = 0
    // XXX add gui check step?
    var number_reloadingImages: Int = 0
    var number_painting: Int = 0
    var number_writingOutputFile: Int = 0
    var number_complete: Int = 0

    var label_text: String = "Started"

    var image_sequence_size: Int = 0
    
    init(framesToCheck: FramesToCheck) {
        self.framesToCheck = framesToCheck
    }
    
    func update() async {
        if framesToCheck.isDone() {
            await MainActor.run {
                frame = nil
                outlierViews = []
                image = Image(systemName: "globe")
            }
        }
        if let frame = frame {
            label_text = "frame \(frame.frame_index)"
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
            await MainActor.run {
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
    @State private var selection_causes_painting = true
    @State private var running = false

    @State private var zstack_frame: CGSize = .zero

    // this sets the original scale factor of the frame zoom view
    // it would be best to calculate this based upon the size of the
    // frame vs the size of the are to show it in
    @State private var scale: CGFloat = 0.25

    @State private var drag_start: CGPoint?
    @State private var drag_end: CGPoint?
    @State private var isDragging = false
      
    @State private var done_frames: [Int: Bool] = [:] // frame_index to done

    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel

    }

    // this is the frame with outliers on top of it
    func frameView( _ image: Image) -> some View {
        return ZStack {
            image

            if showOutliers {
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
                          Color.green).opacity(0.1))
                  .overlay(
                    Rectangle()
                      .stroke(style: StrokeStyle(lineWidth: 1))
                      .foregroundColor((selection_causes_painting ?
                                          Color.red : Color.green).opacity(0.5))
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
            Rectangle()
              .foregroundColor(bg_color)
            Text("\(frame_index)")
            // XXX add status
        }
          .frame(width: 80, height: 50)
          .onTapGesture {
              Task {
                  // grab frame and try to show it
                  if let next_frame = viewModel.framesToCheck.frame(atIndex: frame_index),
                     let baseImage = try await next_frame.baseImage()
                  {
                      viewModel.frame = next_frame
                      viewModel.image = Image(nsImage: baseImage)
                      await viewModel.update()
                  } else {
                      viewModel.frame = nil
                      viewModel.outlierViews = []
                      viewModel.image = Image(systemName: "person")
                      await viewModel.update()
                  }
              }
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
                    Image(systemName: "globe")
                      .imageScale(.large)
                      .foregroundColor(.accentColor)
                }
                HStack {
                    Text(viewModel.label_text)
                    if viewModel.outlierCount > 0 {
                        Text("has \(viewModel.outlierCount) outliers")
                    }
                }
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
                            Button(action: {
                                // XXX move this task to a method somewhere else
                                let foobar = viewModel.frame
                                viewModel.frame = nil
                                viewModel.label_text = "loading..."
                                // XXX set loading image here
                                Task {
                                    if let frame_to_remove = foobar {
                                        //await viewModel.framesToCheck.remove(frame: frame_to_remove)
                                        
                                        if let eraser = viewModel.eraser,
                                           let fp = eraser.final_processor
                                        {
                                            var finish_this_one = true
                                            if let done_already = done_frames[frame_to_remove.frame_index],
                                               done_already
                                            {
                                                finish_this_one = false
                                            }
                                            if finish_this_one {
                                                // add to final queue
                                                done_frames[frame_to_remove.frame_index] = true
                                                await fp.final_queue.add(atIndex: frame_to_remove.frame_index) {
                                                    Log.i("frame \(frame_to_remove.frame_index) finishing")
                                                    try await frame_to_remove.finish()
                                                    Log.i("frame \(frame_to_remove.frame_index) finished")
                                                }
                                            }
                                        }
                                    }
                                    if let next_frame = viewModel.framesToCheck.nextFrame(),
                                       let baseImage = try await next_frame.baseImage()
                                    {
                                        viewModel.frame = next_frame
                                        viewModel.image = Image(nsImage: baseImage)
                                        await viewModel.update()
                                    } else {
                                        viewModel.frame = nil
                                        viewModel.outlierViews = []
                                        viewModel.image = Image(systemName: "person")
                                        await viewModel.update()
                                    }
                                }
                            }) {
                                Text("DONE").font(.largeTitle)
                            }.buttonStyle(PlainButtonStyle())
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
                        Button(action: {
                            Task {
                                await viewModel.frame?.userSelectAllOutliers(toShouldPaint: false)
                                await viewModel.update()
                            }
                        }) {
                            Text("Clear All").font(.largeTitle)
                        }.buttonStyle(PlainButtonStyle())
                    }
                    HStack {
                        Toggle("show outliers", isOn: $showOutliers)
                        Toggle("selection causes paint", isOn: $selection_causes_painting)
                    }

                    if viewModel.image_sequence_size > 0 {
                        // the filmstrip at the bottom
                        ScrollView(.horizontal) {
                            HStack(spacing: 5) {
                                ForEach(0..<viewModel.image_sequence_size, id: \.self) { frame_index in
                                    self.filmStripView(forFrame: frame_index)
                                    
                                }
                            }
                        }.frame(maxWidth: .infinity, maxHeight: 50)
                    }

                    
                /*
                 this looks bad and barely works, replace it with a filmstrip
                HStack {
                    Text("\(viewModel.number_unprocessed) unprocessed")
                    Text("\(viewModel.number_loadingImages) loadingImages")
                    Text("\(viewModel.number_detectingOutliers) detectingOutliers")
                    Text("\(viewModel.number_readyForInterFrameProcessing) readyForInterFrameProcessing")
                    Text("\(viewModel.number_interFrameProcessing) interFrameProcessing")
                    Text("\(viewModel.number_outlierProcessingComplete) outlierProcessingComplete")
                    // XXX add gui check step?
                    Text("\(viewModel.number_reloadingImages) reloadingImages")
                    Text("\(viewModel.number_painting) painting")
                    Text("\(viewModel.number_writingOutputFile) writingOutputFile")
                    Text("\(viewModel.number_complete) complete")
                    }
                 */
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
              .padding()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: ViewModel(framesToCheck: FramesToCheck()))
    }
}


