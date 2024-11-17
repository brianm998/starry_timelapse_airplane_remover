import SwiftUI
import StarCore
import logging

@MainActor
struct InitialView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    @State private var previously_opened_sheet_showing_item: String = ""
    
    var body: some View {
        VStack {
            Spacer()
              .frame(maxHeight: 20)
            Text("Welcome to The Star,")
              .font(.largeTitle)
              .foregroundColor(.white)
            Spacer()
              .frame(maxHeight: 10)
            Text("The Starry Timelapse Airplane Remover")
                .font(.largeTitle)
                .foregroundColor(.white)
            Spacer()
              .frame(maxHeight: 200)
            Text("Choose an option to get started")
              .foregroundColor(.white)

            VStack {
                Text("Drop Here")

            }
              .frame(maxWidth: 250, maxHeight: 250)
              .background(.gray)

            HStack {
                VStack {
                    HStack {
                        Button(action: self.loadConfig) {
                            Text("Load Config").font(.largeTitle)
                        }.buttonStyle(ShrinkingButton())
                          .help("Load a json config file from a previous run of star")
//                          .cursor3(.pointingHand)
                        
                        Button(action: self.loadImageSequence) {
                            Text("Load Image Sequence").font(.largeTitle)
                        }.buttonStyle(ShrinkingButton())
                          .help("Load an image sequence yet to be processed by star")
                    }
                    if viewModel.userPreferences.recentlyOpenedSequencelist.count > 0 {
                        HStack {
                            Button(action: self.loadRecent) {
                                Text("Open Recent").font(.largeTitle)
                            }.buttonStyle(ShrinkingButton())
                              .help("open a recently processed sequence")
                            
                            Picker("\u{27F6}", selection: $previously_opened_sheet_showing_item) {
                                let array = viewModel.userPreferences.sortedSequenceList
                                ForEach(array, id: \.self) { option in
                                    Text(option)
                                }
                            }.frame(maxWidth: 500)
                              .pickerStyle(.menu)
                        }
                    }
                    Spacer()
                      .frame(maxHeight: 20)
                }
            }
        }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
          .background(viewModel.backgroundColor)
          .onAppear {
              if viewModel.userPreferences.sortedSequenceList.count > 0 {
                  previously_opened_sheet_showing_item = viewModel.userPreferences.sortedSequenceList[0]
              }
          }
                    //              // this works great for config files, but not for directories
            //              .dropDestination(for: Config.self) { items, _ in
            //                  if items.count > 0 {
            //                      let config = items[0]
            //                      print("FUCKING config \(items)")
            //                  }
            //                  return true
            //              }
          .onDrop(of: [.fileURL], isTargeted: nil) { providers, _ in
              handleDrop(providers: providers)
          }

    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadObject(ofClass: NSPasteboard.PasteboardType.self) {
                pasteboardItem, _ in
                if let pasteboardItem {
                    if let url = URL(string: pasteboardItem.rawValue) {
                        print("FUCKING url \(url)")

                        // handle json config files
                        // and directories full of files
                        // and later video files
                        
                        var isDir: ObjCBool = false
                        
                        if FileManager.default.fileExists(atPath: url.path,
                                                          isDirectory: &isDir) {
                            if isDir.boolValue {
                                // startup with a new sequence dir
                                Task { @MainActor in
                                    startupWithSequenceDir(url.path)
                                }
                               // return true
                            } else if url.path.hasSuffix(".json") {
                                // try to parse out a config file
                                do {
                                    let config = try Config.read(fromJsonFilename: url.path)
                                    Task { @MainActor in
                                        try await self.viewModel.startup(withConfig: config)
                                        self.viewModel.userPreferences.justOpened(filename: url.path)
                                    }
                                //    return true
                                } catch {
                                    Log.e("cannot load \(url.path): \(error)")
                                    // XXX show view error
                                    Task { @MainActor in
                                        self.handle(error: "\(error)")
                                    }
                                }
                            } else {
                                Task { @MainActor in
                                    self.handle(error: "Unsupported file type \(url.path)")
                                }
                            }
                        } else {
                            print("FUCKING FUCK url \(url)")
                            Task { @MainActor in
                                self.handle(error: "File does not exist: \(url.path)")
                            }
                        }
                    }
                }
            }
        }
        
        return false
    }

    func handle(error: String) {
        self.viewModel.report(error: error)
        self.viewModel.imageSequence = nil
        self.viewModel.isLoadingImageSequence = false
    }
    
    func loadConfig()  {
        Log.d("load config")

        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        let response = openPanel.runModal()
        if response == .OK {
            if let returnedUrl = openPanel.url
            {
                let path = returnedUrl.path
                Log.d("url path \(path)")

                viewModel.eraserTask = Task.detached(priority: .userInitiated) {
                    do {
                        try await viewModel.startup(withConfigFile: path)
                        Task { @MainActor in
                            viewModel.imageSequence?.initialLoadInProgress = true
                        }
                        
                       // Log.d("viewModel.eraser \(String(describing: await viewModel.eraser))")
                        try await viewModel.imageSequence?.eraser?.run()
                    } catch {
                        Log.e("\(error)")
                        await MainActor.run {
                            self.handle(error: "\(error)")
                        }
                    }
                }
            }
        }
    }

    func loadImageSequence() {
        Log.d("load image sequence")
        let openPanel = NSOpenPanel()
        //openPanel.allowedFileTypes = ["json"]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        let response = openPanel.runModal()
        if response == .OK {
            if let returnedUrl = openPanel.url {
                let path = returnedUrl.path
                Log.d("url path \(path)")

                startupWithSequenceDir(path)
            }
        }
    }

    func startupWithSequenceDir(_ path: String) {
        viewModel.eraserTask = Task.detached(priority: .userInitiated) {
            do {
                try await viewModel.startup(withNewImageSequence: path)
                Task { @MainActor in
                    await viewModel.imageSequence?.initialLoadInProgress = true
                }
                try await viewModel.imageSequence?.eraser?.run()
            } catch {
                Log.e("\(error)")
                await MainActor.run {
                    self.handle(error: "\(error)")
                }
            }
        }
    }

    func loadRecent() {
        Log.d("load image sequence")
        
        viewModel.eraserTask = Task.detached(priority: .userInitiated) {
            do {
              try await viewModel.startup(withConfigFile: previously_opened_sheet_showing_item)
                Task { @MainActor in
                    await viewModel.imageSequence?.initialLoadInProgress = true
                }
                try await viewModel.imageSequence?.eraser?.run()
            } catch {
                Log.e("\(error)")
                await MainActor.run {
                    self.handle(error: "\(error)")
                }
            }
        }
    }
}
