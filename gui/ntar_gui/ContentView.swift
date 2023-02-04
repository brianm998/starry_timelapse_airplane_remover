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
                    outlierGroups = await frame.outlierGroups()
                    Log.w("we have \(outlierGroups.count) outlierGroups")
                    outlierImages = []
                    for group in self.outlierGroups {
                        Log.w("we have group \(group)")
                        if let cgImage = await group.testImage() {
                            var size = CGSize()
                            size.width = CGFloat(cgImage.width)
                            size.height = CGFloat(cgImage.height)
                            /* 
                            let outlierImage = Image(nsImage: NSImage(cgImage: cgImage,
                            size: size))
                               */
                            let outlierImage = NSImage(cgImage: cgImage,
                                                       size: size/*.zeroXXX*/)

                            outlierImages.append(outlierImage)
                            Log.w("outlierImages has \(outlierImages.count) items")
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
    var outlierGroups: [OutlierGroup] = []
    var outlierImages: [NSImage] = []
    var image: Image? {
        didSet { self.objectWillChange.send() }
    }

    init(framesToCheck: FramesToCheck) {
        self.framesToCheck = framesToCheck
    }
}

struct ContentView: View {
    @ObservedObject var image: ImageView
    
    var body: some View {
        VStack {
            if let image_f = image.image {
                ZStack {
                    /*
                    Image(systemName: "person")
                      .imageScale(.large)
                      .foregroundColor(.accentColor)
*/
                    image_f
                      .imageScale(.large)

                    if image.outlierImages.count != 0 {
                        /*
                        Image(systemName: "globe")
                          .imageScale(.large)
                          .foregroundColor(.accentColor)
                         */
                        Image(nsImage: image.outlierImages[0])
                          .position(x: 0, y:0 ) // at the top of window, not image :(
//                          .offset(x: CGFloat(0), y: CGFloat(0)) // offset from center
                    }

                    ForEach(0..<image.outlierImages.count) { idx in

                        // XXX this is always empty for some reason :(
                        /*
                        Image(systemName: "globe")
                          .imageScale(.large)
                          .foregroundColor(.accentColor)
                         */
                        Image(nsImage: image.outlierImages[idx])
                          .imageScale(.large)
                          .foregroundColor(.accentColor)

/*
                        .frame(width: 200, height: 200)
 */
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
                            try await image.eraser?.run()
                        } catch {
                            Log.e("\(error)")
                        }
                    }
                }) {
                    Text("START").font(.largeTitle)
                }.buttonStyle(PlainButtonStyle())
                Button(action: {
                    Task {
                        if let frame_to_remove = image.frame {
                            if let eraser = image.eraser,
                               let fp = eraser.final_processor
                            {
                                // add to final queue somehow
                                await fp.final_queue.add(atIndex: frame_to_remove.frame_index) {
                                    Log.i("frame \(frame_to_remove.frame_index) finishing")
                                    try await frame_to_remove.finish()
                                    Log.i("frame \(frame_to_remove.frame_index) finished")
                                }
                            }
                            await image.framesToCheck.remove(frame: frame_to_remove)
                        }
                        if let next_frame = await image.framesToCheck.nextFrame(),
                           let baseImage = try await next_frame.baseImage()
                        {
                            image.frame = next_frame
                            image.image = Image(nsImage: baseImage)
                        } else {
                            image.frame = nil
                            image.image = Image(systemName: "person")
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
        ContentView(image: ImageView(framesToCheck: FramesToCheck()))
    }
}
