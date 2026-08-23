//
//  ContentView.swift
//  star
//
//  Created by Brian Martin on 2/1/23.
//

import SwiftUI

import StarCore
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
        // An overlay, deliberately, and not a member of the `ZStack` above: an overlay is
        // sized by what it is attached to and reports nothing back, so — unlike the panels in
        // that stack — no banner can ever be the reason this window changes size.  Measured
        // both ways while fixing exactly that bug; see the note on `.alert` below.
        .overlay(alignment: .top) {
            if let warning = viewModel.bannerWarning {
                WarningBannerView(warning: warning) { viewModel.dismissBanner() }
            }
        }
        // Critical `StarWarning`s — the machine is about to stop this run, or a previous run
        // was already stopped — go through the system alert rather than one of the hand-drawn
        // panels above.
        //
        // This used to be one of them, and that panel resized the window.  A panel added to
        // the root `ZStack` is a sibling of everything else in it, so its minimum size becomes
        // part of the window's — and this one's minimum height was unbounded: the message and
        // the suggestion were `fixedSize`d vertically, which at a narrow proposed width wraps
        // them into an arbitrarily tall column.  AppKit then grew the window to satisfy that
        // minimum, which is a window that cannot be shrunk back while the alert is up and that
        // stays oversized after it goes away.  Measured: a window sized to 900x600 was forced
        // to 900x4180 with a matching minimum height (`WarningAlertTests`), and on a real run
        // over a 4240x2832 sequence the main window ended up 1452x3104 on a screen 1440 points
        // tall.
        //
        // A system alert is its own window: it contributes nothing to the layout of this one,
        // and its OK button dismisses it through the binding rather than through a button we
        // place ourselves inside the content.
        .alert(viewModel.warningTitle, isPresented: $bindableViewModel.showWarningAlert) {
            Button(localized("ui.ok")) { viewModel.acknowledgeWarning() }
        } message: {
            Text(viewModel.warningAlertText)
        }
    }

    var closeConfirmationAlert: some View {
        ZStack {
            Rectangle()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.gray)
              .opacity(0.5)

            VStack(spacing: 0) {
                Text(localized("ui.work_in_progress"))
                  .font(.headline)
                  .padding(.bottom, 16)
                Text(viewModel.closeConfirmationMessage)
                  .multilineTextAlignment(.center)
                  .padding(.bottom, 24)
                HStack(spacing: 16) {
                    Button(localized("ui.cancel")) {
                        viewModel.showCloseConfirmation = false
                        viewModel.closeConfirmationAction = nil
                    }
                    Button(localized("ui.stop_and_close")) {
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
                Text(localized("ui.error"))

                Spacer()
                  .frame(maxHeight: 40)
                Text(viewModel.errorMessage)
                Spacer()
                  .frame(maxHeight: 40)
                Button() {
                    viewModel.showErrorAlert = false
                } label: {
                    Text(localized("ui.close"))
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
    @State private var showProcessingWindowInfo = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(localized("ui.preferences"))
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
                            Text(localized("ui.processing_type"))
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
                            Text(localized("ui.the_detection_method_used_for_outlier"))
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
                            Text(localized("ui.frame_rate"))
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
                            Text(localized("ui.not_set"))
                                .foregroundColor(.gray)
                                .font(.caption)
                        }

                        if showFrameRateInfo {
                            Text(localized("ui.the_frame_rate_of_the_incoming_and_outgoing"))
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
                            Text(localized("ui.show_horizon_on_main_view"))
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
                            Text(localized("ui.when_enabled_the_horizon_line_will_be"))
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
                            Text(localized("ui.show_horizon_painter_instructions"))
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
                            Text(localized("ui.when_enabled_startup_instructions_will_be"))
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
                            Text(localized("ui.skip_render_prompt_after_processing"))
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
                            Text(localized("ui.when_enabled_the_render_prompts_before_and"))
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
                            Text(localized("ui.show_processing_window"))
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                            Toggle(isOn: Binding(
                                // Unset means shown: this is the default, and the
                                // preference exists to turn it off.
                                get: { viewModel.userPreferences.showProcessingWindow ?? true },
                                set: { newValue in
                                    viewModel.userPreferences.showProcessingWindow = newValue
                                }
                            )) { }
                            .toggleStyle(.switch)
                            Button(action: { showProcessingWindowInfo.toggle() }) {
                                Image(systemName: showProcessingWindowInfo ? "chevron.up" : "chevron.down")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if showProcessingWindowInfo {
                            Text(localized("ui.when_enabled_a_window_showing_each"))
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
                    Text(localized("ui.close"))
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

/// The quiet end of `StarWarning`: a strip across the top of the window for conditions that
/// are worth knowing about but not worth stopping for — the system asking for memory back,
/// star pausing work because the machine is busy, a repeat of something already acknowledged.
///
/// Coloured by severity the same way the Kotlin client's banner is, so the two clients do not
/// describe the same condition with different urgency.  Yellow is "star noticed"; red is a
/// critical condition being mentioned again after the user has already dealt with its alert.
///
/// The width is fixed rather than bounded by `maxWidth`.  That is what keeps the text's height
/// finite: with a maximum-only width the layout is free to propose the width of the longest
/// word, at which point wrapped text grows without limit — which is precisely what made the
/// old warning panel resize the whole window.
struct WarningBannerView: View {
    let warning: StarWarning
    let dismiss: () -> Void

    private static let width: CGFloat = 620

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(localized("ui.warning_banner", warning.title))
                  .font(.headline)
                Text(warning.message)
                  .font(.caption)
                  .fixedSize(horizontal: false, vertical: true)
                if let suggestion = warning.suggestion {
                    Text(suggestion)
                      .font(.caption)
                      .opacity(0.75)
                      .fixedSize(horizontal: false, vertical: true)
                }
            }
              .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            Button(localized("ui.dismiss")) { dismiss() }
              .buttonStyle(.plain)
              .font(.caption)
        }
          .foregroundColor(.black)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .frame(width: WarningBannerView.width, alignment: .leading)
          .background(warning.severity == .critical
                        ? Color.red.opacity(0.94)
                        : Color.yellow.opacity(0.94))
          .cornerRadius(10)
          .padding(.top, 10)
    }
}
