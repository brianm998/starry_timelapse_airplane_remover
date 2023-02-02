//
//  ntar_guiApp.swift
//  ntar_gui
//
//  Created by Brian Martin on 2/1/23.
//

import SwiftUI
import ntar

@main
struct ntar_guiApp: App {

    init() {
        Log.handlers[.console] = ConsoleLogHandler(at: .debug)
        Log.w("Starting Up")
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
