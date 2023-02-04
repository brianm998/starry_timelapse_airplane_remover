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

class ViewModel: ObservableObject {
    var framesToCheck: FramesToCheck
    var eraser: NighttimeAirplaneRemover?
    var frame: FrameAirplaneRemover?
    var outlierViews: [OutlierGroupView] = []
    var image: Image? 

    init(framesToCheck: FramesToCheck) {
        self.framesToCheck = framesToCheck
    }
    
    func update() async {
        if let frame = frame {
            Log.w("view model update for \(frame.frame_index)")
            Log.w("did set frame 1")
            
            Log.w("did set frame in task")
            let (outlierGroups, frame_width, frame_height) =
              await (frame.outlierGroups(), frame.width, frame.height)
            
            Log.w("we have \(outlierGroups.count) outlierGroups")
            outlierViews = []
            for group in outlierGroups {
                Log.w("we have group \(group)")
                if let cgImage = await group.testImage() {
                    var size = CGSize()
                    size.width = CGFloat(cgImage.width)
                    size.height = CGFloat(cgImage.height)
                    let outlierImage = NSImage(cgImage: cgImage,
                                               size: size)

                    let groupView = await OutlierGroupView(group: group,
                                                           name: group.name,
                                                           bounds: group.bounds,
                                                           image: outlierImage,
                                                           frame_width: frame_width,
                                                           frame_height: frame_height)
                    outlierViews.append(groupView)
                    Log.w("outlierViews has \(outlierViews.count) items")
                } else {
                    Log.e("NO FUCKING IMAGE")
                }
            }
            await MainActor.run {
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
    
    var body: some View {
        VStack {
            if let image_f = viewModel.image {
                ZStack {
                    image_f
                      .imageScale(.large)

                        /*
                         why does this foreach fail?
                         last done not properly handled anymore
                         */

                    if showOutliers {

                        // XXX this VVV sucks badly, why the 100?
                        ForEach(0..<100/*viewModel.outlierViews.count*/) { idx in

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
                                      Task {
                                          if let origShouldPaint = await outlierViewModel.group.shouldPaint {
                                              // change the paintability of this outlier group
                                              // set it to user selected opposite previous value
                                              await outlierViewModel.group.shouldPaint(
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

                    // add to ZStack with clickable outlier groups on top
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
