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

    init(framesToCheck: FramesToCheck) {
        self.framesToCheck = framesToCheck
    }
    
    func update() async {
        if await framesToCheck.nextFrame() == nil {
            await MainActor.run {
                frame = nil
                outlierViews = []
                image = Image(systemName: "globe")
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
    @State private var running = false

    @State private var zstack_frame: CGSize = .zero

    @State private var scale: CGFloat = 1
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel

    }

    // this is the frame with outliers on top of it
    func frameView( _ image: Image) -> some View {

        return ZStack {
            image
                        /*
                         why does this foreach fail?
                         last done not properly handled anymore
                         */

            if showOutliers {

                // XXX this VVV sucks badly, why the 100?
                // some kind of race condition with ForEach?
                // everything shows up fine when toggling showOutliers for some reason
                //let fuck = 10000
                //let fuck = viewModel.outlierViews.count
                //let fuck = viewModel.outlierCount
                //Users/brian/git/nighttime_timelapse_airplane_remover/gui/ntar_gui/ContentView.swift:104:39 Non-constant range: argument must be an integer literal
                
                // add to ZStack with clickable outlier groups on top
                ForEach(0 ..< 10000) { idx in
                    
                    if idx < viewModel.outlierViews.count {
                        let outlierViewModel = viewModel.outlierViews[idx]
                        
                        let frame_center_x = outlierViewModel.frame_width/2
                        let frame_center_y = outlierViewModel.frame_height/2
                        let outlier_center = outlierViewModel.bounds.center
                        
                        Image(nsImage: outlierViewModel.image)
                        // offset from the center of parent view
                          .offset(x: CGFloat(outlier_center.x - frame_center_x),
                                  y: CGFloat(outlier_center.y - frame_center_y))
                          .onTapGesture {
                              Log.d("tapped")
                              Task {
                                  if let origShouldPaint = outlierViewModel.group.shouldPaint {
                                      // change the paintability of this outlier group
                                      // set it to user selected opposite previous value
                                      outlierViewModel.group.shouldPaint(
                                        .userSelected(!origShouldPaint.willPaint))
                                      
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
        }
    }

    var body: some View {
        let scaling_anchor = UnitPoint(x: 0.75, y: 0.75)
        VStack {
            if let frame_image = viewModel.image {
                ZoomableView(size: CGSize(width: viewModel.frame_width,
                                          height: viewModel.frame_height),
                             min: 0.2,
                             max: 20,
                             showsIndicators: true,
                             scale: $scale)
                {
                    self.frameView(frame_image)
                      //.resizable()
                      .scaledToFit()
                      .clipped()
                      //.frame(maxWidth: self.width, maxHeight: self.height)
                }

            } else {
                Image(systemName: "globe")
                  .imageScale(.large)
                  .foregroundColor(.accentColor)
            }
            if let frame = viewModel.frame {
                Text("frame \(frame.frame_index)")
            } else {
                Text("Hello, world!")
            }
            VStack {
                HStack {
                    if !running {
                        Button(action: { // XXX hide when running
                            running = true                                
                            Log.w("FKME")
                            Task.detached(priority: .background) {
                                do {
                                    try await viewModel.eraser?.run()
                                } catch {
                                    Log.e("\(error)")
                                }
                            }
                        }) {
                            Text("START").font(.largeTitle)
                        }.buttonStyle(PlainButtonStyle())
                    } else {
                        Button(action: {
                                   // XXX move this task to a method somewhere else
                            Task {
                                if let frame_to_remove = viewModel.frame {
                                    if let eraser = viewModel.eraser,
                                       let fp = eraser.final_processor
                                    {
                                        // add to final queue somehow
                                        await fp.final_queue.add(atIndex: frame_to_remove.frame_index) {
                                            Log.i("frame \(frame_to_remove.frame_index) finishing")
                                            try await frame_to_remove.finish()
                                            Log.i("frame \(frame_to_remove.frame_index) finished")
                                        }
                                    }
                                    await viewModel.framesToCheck.remove(frame: frame_to_remove)
                                }
                                if let next_frame = await viewModel.framesToCheck.nextFrame(),
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
                    }
                }
                Toggle("show outliers", isOn: $showOutliers)
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
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: ViewModel(framesToCheck: FramesToCheck()))
    }
}


