//
//  ContentView.swift
//  star
//
//  Created by Brian Martin on 2/1/23.
//

import SwiftUI

// the overall view of the app
@available(macOS 13.0, *)
struct ContentView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    var body: some View {
        @Bindable var bindableViewModel = viewModel
        return ZStack {
            if viewModel.isLoadingImageSequence {
                ImageSequenceLoadingView()
            } else if let imageSequenceViewModel = viewModel.imageSequence {
                CursorView(cursor: viewModel.cursor) {
                    ImageSequenceView()
                      .environment(imageSequenceViewModel)
                      .navigationTitle(imageSequenceViewModel.windowTitle)
                }
            } else {
                CursorView(cursor: viewModel.cursor) {
                    InitialView()
                }
            }
            // these may show on top
            if viewModel.showInfoDialog { InfoDialogView() }
            if viewModel.showErrorAlert { self.errorAlert }
            if viewModel.showCloseConfirmation { self.closeConfirmationAlert }
        }
        .sheet(isPresented: $bindableViewModel.showUserPreferencesSheet) {
            UserPreferencesEditingView(viewModel: viewModel)
        }
    }

    var closeConfirmationAlert: some View {
        ZStack {
            Rectangle()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.gray)
              .opacity(0.5)

            VStack(spacing: 0) {
                Text("Work In Progress")
                  .font(.headline)
                  .padding(.bottom, 16)
                Text(viewModel.closeConfirmationMessage)
                  .multilineTextAlignment(.center)
                  .padding(.bottom, 24)
                HStack(spacing: 16) {
                    Button("Cancel") {
                        viewModel.showCloseConfirmation = false
                        viewModel.closeConfirmationAction = nil
                    }
                    Button("Stop and Close") {
                        let action = viewModel.closeConfirmationAction
                        viewModel.showCloseConfirmation = false
                        viewModel.closeConfirmationAction = nil
                        action?()
                    }
                    .foregroundColor(.red)
                }
            }
              .padding(40)
              .frame(maxWidth: 480)
              .background(.regularMaterial)
              .cornerRadius(16)
        }
    }

    var errorAlert: some View {
        ZStack {
            Rectangle()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.gray)
              .opacity(0.5)

            VStack {
                Text("ERROR")

                Spacer()
                  .frame(maxHeight: 40)
                Text(viewModel.errorMessage)
                Spacer()
                  .frame(maxHeight: 40)
                Button() {
                    viewModel.showErrorAlert = false
                } label: {
                    Text("Close")
                }
            }
              .padding(40)
              .frame(maxWidth: 500)
              .background(.red)
              .cornerRadius(20)
        }
    }
}

struct UserPreferencesEditingView: View {
    @Environment(\.dismiss) var dismiss
    var viewModel: ViewModel

    @State private var showProcessingTypeInfo = false
    @State private var showFrameRateInfo = false
    @State private var showCodecInfo = false
    @State private var showEncoderInfo = false
    @State private var showPixelFormatInfo = false
    @State private var showMuxerInfo = false
    @State private var showHorizonOnMainViewInfo = false
    @State private var showHorizonPainterInstructionsInfo = false
    @State private var showSkipRenderPromptInfo = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preferences")
                    .font(.title)
                    .foregroundColor(.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.gray)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()
            .background(Color(red: 0.15, green: 0.15, blue: 0.15))

            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Processing Type")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                            Button(action: { showProcessingTypeInfo.toggle() }) {
                                Image(systemName: showProcessingTypeInfo ? "chevron.up" : "chevron.down")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if let processingType = viewModel.userPreferences.processingType {
                            Text(processingType.rawValue)
                                .foregroundColor(.gray)
                                .font(.caption)
                        }

                        if showProcessingTypeInfo {
                            Text("The detection method used for outlier detection. 'Strong' is more aggressive, while 'Weak' is more conservative.")
                                .foregroundColor(.white)
                                .font(.body)
                                .padding(8)
                                .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                                .cornerRadius(4)
                        }
                    }
                    .padding()
                    .background(Color(red: 0.12, green: 0.12, blue: 0.12))
                    .cornerRadius(6)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Frame Rate")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                            Button(action: { showFrameRateInfo.toggle() }) {
                                Image(systemName: showFrameRateInfo ? "chevron.up" : "chevron.down")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if let frameRate = viewModel.userPreferences.frameRate {
                            Text(String(frameRate.rawValue))
                                .foregroundColor(.gray)
                                .font(.caption)
                        } else {
                            Text("Not set")
                                .foregroundColor(.gray)
                                .font(.caption)
                        }

                        if showFrameRateInfo {
                            Text("The frame rate of the incoming and outgoing video. This affects playback speed and video generation.")
                                .foregroundColor(.white)
                                .font(.body)
                                .padding(8)
                                .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                                .cornerRadius(4)
                        }
                    }
                    .padding()
                    .background(Color(red: 0.12, green: 0.12, blue: 0.12))
                    .cornerRadius(6)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Show Horizon on Main View")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                            Toggle(isOn: Binding(
                                get: { viewModel.userPreferences.showHorizonOnMainView ?? false },
                                set: { newValue in
                                    viewModel.userPreferences.showHorizonOnMainView = newValue
                                }
                            )) { }
                            .toggleStyle(.switch)
                            Button(action: { showHorizonOnMainViewInfo.toggle() }) {
                                Image(systemName: showHorizonOnMainViewInfo ? "chevron.up" : "chevron.down")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if showHorizonOnMainViewInfo {
                            Text("When enabled, the horizon line will be displayed on the main frame editing view for reference.")
                                .foregroundColor(.white)
                                .font(.body)
                                .padding(8)
                                .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                                .cornerRadius(4)
                        }
                    }
                    .padding()
                    .background(Color(red: 0.12, green: 0.12, blue: 0.12))
                    .cornerRadius(6)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Show Horizon Painter Instructions")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                            Toggle(isOn: Binding(
                                get: { viewModel.userPreferences.showHorizonPainterInstructions ?? false },
                                set: { newValue in
                                    viewModel.userPreferences.showHorizonPainterInstructions = newValue
                                }
                            )) { }
                            .toggleStyle(.switch)
                            Button(action: { showHorizonPainterInstructionsInfo.toggle() }) {
                                Image(systemName: showHorizonPainterInstructionsInfo ? "chevron.up" : "chevron.down")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if showHorizonPainterInstructionsInfo {
                            Text("When enabled, startup instructions will be shown in the horizon painter overlay.")
                                .foregroundColor(.white)
                                .font(.body)
                                .padding(8)
                                .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                                .cornerRadius(4)
                        }
                    }
                    .padding()
                    .background(Color(red: 0.12, green: 0.12, blue: 0.12))
                    .cornerRadius(6)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Skip Render Prompt After Processing")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                            Toggle(isOn: Binding(
                                get: { viewModel.userPreferences.skipRenderPromptAfterProcessing ?? false },
                                set: { newValue in
                                    viewModel.userPreferences.skipRenderPromptAfterProcessing = newValue
                                }
                            )) { }
                            .toggleStyle(.switch)
                            Button(action: { showSkipRenderPromptInfo.toggle() }) {
                                Image(systemName: showSkipRenderPromptInfo ? "chevron.up" : "chevron.down")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if showSkipRenderPromptInfo {
                            Text("When enabled, the render prompts before and after processing will be suppressed automatically.")
                                .foregroundColor(.white)
                                .font(.body)
                                .padding(8)
                                .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                                .cornerRadius(4)
                        }
                    }
                    .padding()
                    .background(Color(red: 0.12, green: 0.12, blue: 0.12))
                    .cornerRadius(6)
                }
                .padding()
            }

            HStack {
                Button(action: { dismiss() }) {
                    Text("Close")
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                Spacer()
            }
            .padding()
            .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.1))
    }
}
