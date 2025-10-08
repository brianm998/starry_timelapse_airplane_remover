import AppKit
import SwiftUI
import StarCore
import logging

// A view that shows a new release that is available
struct NewReleaseSheetView: View {

    @Binding var isVisible: Bool
    let viewModel: ViewModel
    let release: GitHubRelease?

    init(isVisible: Binding<Bool>,
         viewModel: ViewModel)
    {
        _isVisible = isVisible
        self.viewModel = viewModel
        release = viewModel.newRelease
    }
    
    var body: some View {
        HStack {
            Space(width: 20)
            if let release,
               let version = release.version
            {
                VStack {
                    Space(height: 20)
                    Text("There is a new release of Star available!")
                      .font(.title)
                    Space(height: 10)
                    Text("You are running Star v\(Config.latestVersion), and Star v\(version) is now available")
                      .font(.title2)

                    Space(height: 20)

                    if let body = release.body {
                        Text("Release Notes:")
                          .font(.title3)
                        ScrollView {
                            Text(body)
                              .padding(10)
                        }
                          .border(.gray.opacity(0.6))
                    }

                    HStack {
                        Link("See Release on GitHub", destination: release.htmlURL)
                          .font(.title)
                          .foregroundColor(.blue)
                          .underline()
                          .padding()
                        
                        if let url = release.packageURL(for: .gui) {
                            Link("Download Star v\(version)", destination: url)
                              .font(.title)
                              .foregroundColor(.blue)
                              .underline()
                              .padding()
                        }
                    }

                    HStack {
                        Button() {
                            self.isVisible = false
                        } label: {
                            Text("Upgrade Later")
                              .font(.title)
                              .padding(20)
                        }

                        Space(width: 30)
                        
                        Button() {
                            self.isVisible = false
                            Task {
                                NSApplication.shared.terminate(nil)
                            }
                        } label: {
                            Text("Quit Star v\(Config.latestVersion)")
                              .font(.title)
                              .padding(20)
                        }
                    }
                    Space(height: 20)
                }
                  .frame(maxHeight: 500)
                  .frame(minWidth: 800)
            } else {
                VStack {
                    Text("There is no new release available")
                    Button() {
                        self.isVisible = false
                    } label: {
                        Text("OK")
                          .font(.title)
                    }
                }
            }
            Space(width: 20)
        }
    }
}
