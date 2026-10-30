import Foundation
import SwiftUI
import StarCore

// an HStack of buttons to advance backwards and fowards through the sequence
struct VideoPlaybackButtons : View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        // XXX these should really use modifiers but those don't work :(
        let start_shortcut_key: KeyEquivalent = "b" // make this bottom arrow
        let fast_previous_shortcut_key: KeyEquivalent = "z"
        let fast_next_shortcut_key: KeyEquivalent = "x"
        let previous_shortcut_key: KeyEquivalent = .leftArrow
        let backwards_shortcut_key: KeyEquivalent = "w"
        let end_button_shortcut_key: KeyEquivalent = "f" // make this top arrow

        let button_color = Color(white: 202/256)

        let buttonSize: CGFloat = 180
        
        return HStack {
            // go to start button

            if !viewModel.videoPlaying {
                SystemButton(named: "backward.end.fill",
                             shortcutKey: start_shortcut_key,
                             color: button_color,
                             toolTip: localized("ui.transport_first_frame"))
                {
                    viewModel.goToFirstFrameButtonAction()
                }
                
                // fast previous button
                SystemButton(named: "backward.fill",
                            shortcutKey: fast_previous_shortcut_key,
                            color: button_color,
                            toolTip: localized("ui.transport_back_frames", viewModel.fastSkipAmount))
                {
                    viewModel.fastPreviousButtonAction()
                }
                
                // previous button
                SystemButton(named: "backward.frame.fill",
                             shortcutKey: previous_shortcut_key,
                             color: button_color,
                             toolTip: localized("ui.transport_previous_frame"))
                {
                    viewModel.transition(numberOfFrames: -1)
                }

                // play backwards button
                SystemButton(named: "arrowtriangle.backward",
                             shortcutKey: backwards_shortcut_key,
                             color: button_color,
                             size: buttonSize,
                             shortcutEnabled: !viewModel.isShowingHorizonPainter,
                             toolTip: localized("ui.transport_play_reverse"))
                {
                    viewModel.videoPlayMode = .reverse
                    viewModel.togglePlay()
                }
            }

            ZStack {
                // backwards button is not shown, so we use this to have shortcut still work
                if viewModel.videoPlaying {
                    Button("") {
                        viewModel.togglePlay()
                    }
                      .opacity(0)
                      .keyboardShortcut(backwards_shortcut_key, modifiers: [])
                      .disabled(viewModel.isShowingHorizonPainter)
                } 
            
                // play/pause button
                SystemButton(named: viewModel.videoPlaying ? "pause.fill" : "play.fill", // pause.fill
                             shortcutKey: " ",
                             color: viewModel.videoPlaying ? .blue : button_color,
                             size: buttonSize,
                             shortcutEnabled: !viewModel.isShowingHorizonPainter,
                             toolTip: localized(viewModel.videoPlaying ? "ui.transport_pause" : "ui.transport_play"))
                {
                    viewModel.videoPlayMode = .forward
                    viewModel.togglePlay()
                    //Log.w("play button not yet implemented")
                }
            }
            if !viewModel.videoPlaying {
                
                // next button
                SystemButton(named: "forward.frame.fill",
                             shortcutKey: .rightArrow,
                             color: button_color,
                             toolTip: localized("ui.transport_next_frame"))
                {
                    viewModel.transition(numberOfFrames: 1)
                }
                
                // fast next button
                SystemButton(named: "forward.fill",
                             shortcutKey: fast_next_shortcut_key,
                             color: button_color,
                             toolTip: localized("ui.transport_forward_frames", viewModel.fastSkipAmount))
                {
                    viewModel.fastForwardButtonAction()
                }
                
                
                // end button
                SystemButton(named: "forward.end.fill",
                             shortcutKey: end_button_shortcut_key,
                             color: button_color,
                             toolTip: localized("ui.transport_last_frame"))
                {
                    viewModel.goToLastFrameButtonAction()
                }
            }
        }        
    }
}
