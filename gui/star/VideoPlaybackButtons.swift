import Foundation
import SwiftUI

// an HStack of buttons to advance backwards and fowards through the sequence
struct VideoPlaybackButtons : View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    var body: some View {
        // XXX these should really use modifiers but those don't work :(
        let start_shortcut_key: KeyEquivalent = "b" // make this bottom arror
        let fast_previous_shortcut_key: KeyEquivalent = "z"
        let fast_next_shortcut_key: KeyEquivalent = "x"
        let previous_shortcut_key: KeyEquivalent = .leftArrow
        let backwards_shortcut_key: KeyEquivalent = "r"
        let end_button_shortcut_key: KeyEquivalent = "f" // make this top arror

        let button_color = Color(white: 202/256)

        let buttonSize: CGFloat = 180
        
        return HStack {
            // go to start button

            if !viewModel.videoPlaying {
                SystemButton(named: "backward.end.fill",
                             shortcutKey: start_shortcut_key,
                             color: button_color,
                             toolTip: """
                               go to start of sequence
                               (keyboard shortcut '\(start_shortcut_key.character)')
                               """)
                {
                    viewModel.goToFirstFrameButtonAction()
                }
                
                // fast previous button
                SystemButton(named: "backward.fill",
                            shortcutKey: fast_previous_shortcut_key,
                            color: button_color,
                            toolTip: """
                              back \(viewModel.fastSkipAmount) frames
                              (keyboard shortcut '\(fast_previous_shortcut_key.character)')
                              """)
                {
                    viewModel.fastPreviousButtonAction()
                }
                
                // previous button
                SystemButton(named: "backward.frame.fill",
                             shortcutKey: previous_shortcut_key,
                             color: button_color,
                             toolTip: """
                               back one frame
                               (keyboard shortcut left arrow)
                               """)
                {
                    viewModel.transition(numberOfFrames: -1)
                }

                // play backwards button
                SystemButton(named: "arrowtriangle.backward",
                             shortcutKey: backwards_shortcut_key,
                             color: button_color,
                             size: buttonSize,
                             toolTip: """
                               play in reverse
                               (keyboard shortcut '\(backwards_shortcut_key)')
                               """)
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
                } 
            
                // play/pause button
                SystemButton(named: viewModel.videoPlaying ? "pause.fill" : "play.fill", // pause.fill
                             shortcutKey: " ",
                             color: viewModel.videoPlaying ? .blue : button_color,
                             size: buttonSize,
                             toolTip: """
                               Play / Pause
                               """)
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
                             toolTip: """
                               forward one frame
                               (keyboard shortcut right arrow)
                               """)
                {
                    viewModel.transition(numberOfFrames: 1)
                }
                
                // fast next button
                SystemButton(named: "forward.fill",
                             shortcutKey: fast_next_shortcut_key,
                             color: button_color,
                             toolTip: """
                               forward \(viewModel.fastSkipAmount) frames
                               (keyboard shortcut '\(fast_next_shortcut_key.character)')
                               """)
                {
                    viewModel.fastForwardButtonAction()
                }
                
                
                // end button
                SystemButton(named: "forward.end.fill",
                             shortcutKey: end_button_shortcut_key,
                             color: button_color,
                             toolTip: """
                               advance to end of sequence
                               (keyboard shortcut '\(end_button_shortcut_key.character)')
                               """)
                {
                    viewModel.goToLastFrameButtonAction()
                }
            }
        }        
    }
}
