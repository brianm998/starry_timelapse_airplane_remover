import SwiftUI
import StarCore
import logging

struct InitialView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    @State private var previously_opened_sheet_showing_item: String = ""

    var body: some View {
        VStack {
            Spacer()
              .frame(maxHeight: 20)
            Text("Welcome to The Star,")
              .font(.largeTitle)
            Spacer()
              .frame(maxHeight: 10)
            Text("The Starry Timelapse Airplane Remover")
                .font(.largeTitle)
            Spacer()
              .frame(maxHeight: 200)
            Text("Choose an option to get started")
            
            HStack {
                VStack {
                    HStack {
                        Button(action: self.loadConfig) {
                            Text("Load Config").font(.largeTitle)
                        }.buttonStyle(ShrinkingButton())
                          .help("Load a json config file from a previous run of star")
                        
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
          .onAppear {
              if viewModel.userPreferences.sortedSequenceList.count > 0 {
                  previously_opened_sheet_showing_item = viewModel.userPreferences.sortedSequenceList[0]
              }
          }
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
                viewModel.sequenceLoaded = true
                viewModel.initialLoadInProgress = true

                viewModel.eraserTask = Task.detached(priority: .userInitiated) {
                    do {
                        try await viewModel.startup(withConfig: path)
                        
                        Log.d("viewModel.eraser \(String(describing: await viewModel.eraser))")
                        try await viewModel.eraser?.run()
                    } catch {
                        Log.e("\(error)")
                        await MainActor.run {
                            self.viewModel.showErrorAlert = true
                            self.viewModel.errorMessage = "\(error)"
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
            if let returnedUrl = openPanel.url
            {
                let path = returnedUrl.path
                Log.d("url path \(path)")
                
                viewModel.sequenceLoaded = true
                viewModel.initialLoadInProgress = true
                viewModel.eraserTask = Task.detached(priority: .userInitiated) {
                    do {
                        try await viewModel.startup(withNewImageSequence: path)
                        try await viewModel.eraser?.run()
                    } catch {
                        Log.e("\(error)")
                        await MainActor.run {
                            self.viewModel.showErrorAlert = true
                            self.viewModel.errorMessage = "\(error)"
                        }
                    }
                }
            }
        }
    }
                        
    func loadRecent() {
        Log.d("load image sequence")
        
        viewModel.sequenceLoaded = true
        viewModel.initialLoadInProgress = true
        
        viewModel.eraserTask = Task.detached(priority: .userInitiated) {
            do {
                try await viewModel.startup(withConfig: previously_opened_sheet_showing_item)
                try await viewModel.eraser?.run()
            } catch {
                Log.e("\(error)")
                await MainActor.run {
                    self.viewModel.showErrorAlert = true
                    self.viewModel.errorMessage = "\(error)"
                }
            }
        }
    }
}
