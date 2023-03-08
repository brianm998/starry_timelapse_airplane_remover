import SwiftUI
import NtarCore

struct InitialView: View {
    @ObservedObject var viewModel: ViewModel
    @Binding var running: Bool
    @Binding var previously_opened_sheet_showing_item: String

    var body: some View {
        initialView()
    }

    func initialView() -> some View {
        VStack {
            Text("Welcome to the Nighttime Timelapse Airplane Remover")
              .font(.largeTitle)
            Spacer()
              .frame(maxHeight: 200)
            Text("Choose an option to get started")
            
            HStack {
                let loadConfig = {
                    Log.d("load config")

                    let openPanel = NSOpenPanel()
                    openPanel.allowedFileTypes = ["json"]
                    openPanel.allowsMultipleSelection = false
                    openPanel.canChooseDirectories = false
                    openPanel.canChooseFiles = true
                    let response = openPanel.runModal()
                    if response == .OK {
                        if let returnedUrl = openPanel.url
                        {
                            let path = returnedUrl.path
                            Log.d("url path \(path) viewModel.app \(viewModel.app)")
                            running = true
                            viewModel.initial_load_in_progress = true
                            
                            Task.detached(priority: .userInitiated) {
                                do {
                                    await viewModel.app?.startup(withConfig: path)
                            
                                    Log.d("viewModel.eraser \(await viewModel.eraser)")
                                    try await viewModel.eraser?.run()
                                } catch {
                                    Log.e("\(error)")
                                }
                            }
                        }
                    }
                }

                VStack {
                    HStack {
                        Button(action: loadConfig) {
                            Text("Load Config").font(.largeTitle)
                        }.buttonStyle(ShrinkingButton())
                          .help("Load a json config file from a previous run of ntar")
                        
                        let loadImageSequence = {
                            Log.d("load image sequence")
                            let openPanel = NSOpenPanel()
                            //openPanel.allowedFileTypes = ["json"]
                            openPanel.allowsMultipleSelection = false
                            openPanel.canChooseDirectories = true
                            openPanel.canChooseFiles = false
                            let response = openPanel.runModal()
                            if response == .OK {
                                if let returnedUrl = openPanel.url
                                {
                                    let path = returnedUrl.path
                                    Log.d("url path \(path)")
                                    
                                    running = true
                                    viewModel.initial_load_in_progress = true
                                    Task.detached(priority: .userInitiated) {
                                        do {
                                            await viewModel.app?.startup(withNewImageSequence: path)
                                            try await viewModel.eraser?.run()
                                        } catch {
                                            Log.e("\(error)")
                                        }
                                    }
                                }
                            }
                        }
                        
                        Button(action: loadImageSequence) {
                            Text("Load Image Sequence").font(.largeTitle)
                        }.buttonStyle(ShrinkingButton())
                          .help("Load an image sequence yet to be processed by ntar")
                    }
                    if UserPreferences.shared.recentlyOpenedSequencelist.count > 0 {
                        HStack {
                            let loadRecent = {
                                Log.d("load image sequence")
                                
                                running = true
                                viewModel.initial_load_in_progress = true
                                
                                Task.detached(priority: .userInitiated) {
                                    do {
                                        await viewModel.app?.startup(withConfig: previously_opened_sheet_showing_item)
                                        try await viewModel.eraser?.run()
                                    } catch {
                                        Log.e("\(error)")
                                    }
                                }
                            }
                            
                            Button(action: loadRecent) {
                                Text("Open Recent").font(.largeTitle)
                            }.buttonStyle(ShrinkingButton())
                              .help("open a recently processed sequence")
                            
                            Picker("\u{27F6}", selection: $previously_opened_sheet_showing_item) {
                                let array = UserPreferences.shared.sortedSequenceList
                                ForEach(array, id: \.self) { option in
                                    Text(option)
                                }
                            }.frame(maxWidth: 500)
                              .pickerStyle(.menu)
                        }
                    }
                }
            }
        }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}