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
                    Text(localized("ui.there_is_a_new_release_of_star_available"))
                      .font(.title)
                    Space(height: 10)
                    Text(localized("ui.new_release_available", Config.latestVersion, version))
                      .font(.title2)

                    Space(height: 20)

                    if let body = release.body {
                        Text(localized("ui.release_notes"))
                          .font(.title3)
                        ScrollView {
                            Text(body)
                              .padding(10)
                        }
                          .border(.gray.opacity(0.6))
                    }

                    HStack {
                        Link(localized("ui.see_release_on_github"), destination: release.htmlURL)
                          .font(.title)
                          .foregroundColor(.blue)
                          .underline()
                          .padding()
                        
                        if let url = release.packageURL(for: .gui) {
                            Link(localized("ui.download_star", version), destination: url)
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
                            Text(localized("ui.upgrade_later"))
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
                            Text(localized("ui.quit_star", Config.latestVersion))
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
                    Text(localized("ui.there_is_no_new_release_available"))
                    Button() {
                        self.isVisible = false
                    } label: {
                        Text(localized("ui.ok"))
                          .font(.title)
                    }
                }
            }
            Space(width: 20)
        }
    }
}
