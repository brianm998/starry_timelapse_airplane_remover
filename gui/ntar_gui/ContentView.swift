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
    var outlierCount: Int = 0
    var image: Image? 

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

    @State private var width: CGFloat = 0
    @State private var height: CGFloat = 0
    @State private var finalAmount: CGFloat = 0
    @State private var currentAmount: CGFloat = 0
    @State private var offsetX: CGFloat = 0
    @State private var offsetY: CGFloat = 0
    @State private var offsetXBuffer: CGFloat = 0
    @State private var offsetYBuffer: CGFloat = 0

    @State private var positive = true
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel

        if let frame = viewModel.frame { 
            let (frame_width, frame_height) = (frame.width, frame.height)
            
            width = CGFloat(frame_width)
            height = CGFloat(frame_height)
        }
    }
    
    var body: some View {
        VStack {
            if let image_f = viewModel.image {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                ZStack {
                    image_f
                      .resizable()

                    
//                      .frame(width: width, height: height)
                      .scaleEffect(finalAmount + currentAmount)
                      .offset(x: offsetX, y:offsetY)
                    
                      .gesture(
                        DragGesture()
                          .onChanged { value in
                              offsetY = value.translation.height + offsetYBuffer
                              offsetX =  value.translation.width + offsetXBuffer
                          }
                          .onEnded { value in
                              offsetXBuffer = value.translation.width + offsetXBuffer
                              offsetYBuffer = value.translation.height + offsetYBuffer
                          }
                      ).gesture(
                        MagnificationGesture()
                          .onChanged { value in
                              currentAmount = value - 1
                          }
                          .onEnded { value in
                              finalAmount += currentAmount
                              currentAmount = 0
                              if self.positive {
                                  offsetY += 0.1 //this seems to fix it
                              } else {
                                  offsetY -= 0.1 //this seems to fix it
                              }
                              self.positive = !self.positive
                          }
                      )
                    
                    
//                      .imageScale(.large)
                    
                        /*
                         why does this foreach fail?
                         last done not properly handled anymore
                         */

                    if showOutliers {

                        // XXX this VVV sucks badly, why the 100?
                        // some kind of race condition with ForEach?
                        // everything shows up fine when toggling showOutliers for some reason
                        let fuck = 10000
                        //let fuck = viewModel.outlierViews.count
                        //let fuck = viewModel.outlierCount
                        //Users/brian/git/nighttime_timelapse_airplane_remover/gui/ntar_gui/ContentView.swift:104:39 Non-constant range: argument must be an integer literal

                        // add to ZStack with clickable outlier groups on top
                        ForEach(0 ..< fuck) { idx in

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
                }
                //.scaleEffect(self.scale)
                }//.gesture(magnificationGesture)
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
