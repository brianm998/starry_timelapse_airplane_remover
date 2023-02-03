//
//  ContentView.swift
//  ntar_gui
//
//  Created by Brian Martin on 2/1/23.
//

import SwiftUI
import NtarCore

class ImageView: ObservableObject {
    var eraser: NighttimeAirplaneRemover? 
    var image: Image? {
        didSet { self.objectWillChange.send() }
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
            Button(action: {
                Log.w("FKME")
                Task.detached(priority: .background) {
                    do {
                        try await image.eraser?.run()
                    } catch {
                        Log.e("\(error)")
                    }
                }
                Log.w("FKME 2")
            }) {
                Text("FUCK").font(.largeTitle)
            }.buttonStyle(PlainButtonStyle())
            
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(image: ImageView())
    }
}
