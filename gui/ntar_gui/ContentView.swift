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
/*
extension Image: Identifiable {
    public var id: ObjectIdentifier {
        return ObjectIdentifier(self)
    }
}
*/
class ImageView: ObservableObject {
    var framesToCheck: FramesToCheck
    var eraser: NighttimeAirplaneRemover?
    var frame: FrameAirplaneRemover? {
        didSet(newValue) {
            Log.w("did set frame \(frame)")
            if let frame = frame {
                Log.w("did set frame 1")
                Task {
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

                            let groupView = await OutlierGroupView(name: group.name,
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
    }
//    var outlierGroups: [OutlierGroup] = []
    var outlierViews: [OutlierGroupView] = []
    var image: Image? {
        didSet { self.objectWillChange.send() }
    }

    init(framesToCheck: FramesToCheck) {
        self.framesToCheck = framesToCheck
    }
}

struct OutlierGroupView {
    let name: String
    let bounds: BoundingBox
    let image: NSImage
    let frame_width: Int
    let frame_height: Int
}

struct ContentView: View {
    @ObservedObject var viewModel: ImageView
    
    var body: some View {
        VStack {
            if let image_f = viewModel.image {
                ZStack {
                    image_f
                      .imageScale(.large)

                        /*
                         why does this foreach fail?
                         why do we get outlier groups for the wrong frame?
                         get it clickable to change paintability
                         */


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
/*                        
                        Image(nsImage: viewModel.outlierViews[idx])
                          .imageScale(.large)
                          .foregroundColor(.accentColor)

                        .frame(width: 200, height: 200)
 */
                        }
                    }

                    // add to ZStack with clickable outlier groups on top
                }
            } else {
                Image(systemName: "globe")
                  .imageScale(.large)
                  .foregroundColor(.accentColor)
            }
            Text("Hello, world!")
            HStack {
                Button(action: { // XXX hide when running
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
                Button(action: {
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
                        } else {
                            viewModel.frame = nil
                            viewModel.image = Image(systemName: "person")
                        }
                    }
                }) {
                    Text("DONE").font(.largeTitle)
                }.buttonStyle(PlainButtonStyle())
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: ImageView(framesToCheck: FramesToCheck()))
    }
}
