//
//  ContentView.swift
//  ntar_gui
//
//  Created by Brian Martin on 2/1/23.
//

import SwiftUI
import NtarCore

class ImageView: ObservableObject {
    var framesToCheck: FramesToCheck
    var eraser: NighttimeAirplaneRemover?
    var frame: FrameAirplaneRemover?
    // XXX add link to FramesToCheck
    // XXX add link to frame
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
            if let image = image.image
            {
                image
                  .imageScale(.large)
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
