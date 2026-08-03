import SwiftUI
import StarCore
import logging

/// The keypoint divisor, offered in the startup flow instead of only in Advanced settings.
///
/// It is the one setting on this machine that decides whether a large sequence runs at a
/// sensible speed or crawls, and it was three sheets deep — so it is here, in the last
/// startup prompt, on the way to Start Processing.
///
/// Collapsed to its title and left at full resolution when the machine can detect on this
/// sequence at full resolution; expanded and pre-set to
/// `Config.recommendedReducedKeypointDivisor` when it cannot. Which of those it is comes
/// from `Config.keypointDivisorAdvice(physicalMemory:)` — see there for where the boundary
/// is and why.
///
/// Deliberately free of the words keypoint, homography, SIFT and descriptor: someone who
/// just wants their video cleaned up has to be able to make this choice. The Advanced
/// panel's version of the same setting explains the mechanism for those who want it.
struct KeypointDivisorStartupView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    /// Owned by the parent so it survives this view's identity, and so the parent can
    /// decide the initial state from the advice below.
    @Binding var isExpanded: Bool

    /// Text of the free-form field. Kept separate from the divisor rather than bound to
    /// it, because a value being typed goes through states the divisor should not be
    /// pushed into ("1.50" would be reformatted to "1.5" under the cursor).
    @State private var customText: String = ""
    @FocusState private var customFocused: Bool

    /// Guards the one-shot default. `onAppear` can fire more than once for the same view,
    /// and re-running this would stomp a choice the user just made.
    @State private var hasAppliedAdvice = false

    private struct Preset {
        let divisor: Double
        let name: String
        let blurb: String
    }

    /// The three offered values. 1.5 comes from `Config` rather than being written here so
    /// the recommendation and the preset cannot drift apart.
    private static var presets: [Preset] { [
        Preset(divisor: 1.0,
               name: localized("ui.preset_best_quality"),
               blurb: localized("ui.preset_best_quality_blurb")),
        Preset(divisor: Config.recommendedReducedKeypointDivisor,
               name: localized("ui.preset_best_balance"),
               blurb: localized("ui.preset_best_balance_blurb")),
        Preset(divisor: 2.0,
               name: localized("ui.preset_fastest"),
               blurb: localized("ui.preset_fastest_blurb")),
    ] }

    /// Above this, say so. Not a limit — the value is still accepted, because someone
    /// desperate for speed on a machine this footage does not fit may want it anyway.
    private static let tooHighDivisor: Double = 4.0

    /// The largest value the field will accept at all — past here it is not a trade any
    /// more, it is a typo. Exclusive, matching the `maxValue: 8` this same setting already
    /// has in the Advanced panel's `EditableNumberView`, so a value entered here is one
    /// that panel will also accept.
    private static let maxDivisor: Double = 8.0

    private var divisor: Double { viewModel.alignmentKeypointDetectionDivisor }

    private var advice: Config.KeypointDivisorAdvice? {
        viewModel.config.config()
          .keypointDivisorAdvice(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            if isExpanded {
                Space(height: 12)
                explanation
                Space(height: 14)
                presetRows
                Space(height: 12)
                customRow
                if divisor >= Self.tooHighDivisor {
                    Space(height: 6)
                    tooHighWarning
                }
            }
        }
          .frame(maxWidth: 640, alignment: .leading)
          .onAppear { applyAdviceOnce() }
          .onChange(of: customText) { applyCustomTextIfValid() }
          .onChange(of: divisor) {
              // Resync the field when a preset moved the value, but never while it is
              // being typed into — that would rewrite the text under the cursor.
              if !customFocused { customText = Self.format(divisor) }
          }
    }

    private var titleRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Text(isExpanded ? "▼" : "▶")
                  .font(.body)
                  .foregroundColor(.white)
                  .opacity(0.7)
                Text(localized("ui.speed_vs_sharpness"))
                  .font(.title2)
                  .foregroundColor(.white)
                if !isExpanded {
                    Text(localized("ui.current_choice_suffix", currentChoiceName))
                      .font(.title3)
                      .foregroundColor(.white)
                      .opacity(0.7)
                }
                Spacer()
            }
        }
          .buttonStyle(PlainButtonStyle())
          .help(isExpanded ? localized("ui.hide_speed_settings") : localized("ui.show_speed_settings"))
    }

    /// What the collapsed title says is in effect. A custom value has no preset name, so
    /// it shows the number.
    private var currentChoiceName: String {
        if let preset = Self.presets.first(where: { matches($0.divisor) }) {
            return preset.name
        }
        return localized("ui.divide_by", Self.format(divisor))
    }

    private var explanation: some View {
        Text(explanationText)
          .font(.body)
          .foregroundColor(.white)
          .fixedSize(horizontal: false, vertical: true)
    }

    /// Two versions on purpose. Below the machine's crossover there is genuinely nothing
    /// to gain here and saying so is more useful than a recommendation; at or above it,
    /// this is the setting that decides how the run goes, and the numbers explaining why
    /// are the machine's own.
    private var explanationText: String {
        let intro = localized("ui.keypoint_intro")

        guard let advice else {
            // No dimensions yet, so no honest numbers to quote. Describe the trade only.
            return intro + "\n\n" + localized("ui.keypoint_no_numbers")
        }

        let frames = Self.megapixels(advice.imagePixels)
        let ram = Self.memoryDescription

        if advice.reduceRecommended {
            return intro + "\n\n" + localized("ui.keypoint_reduce_recommended",
                                                    frames, ram,
                                                    advice.fullResolutionConcurrency,
                                                    advice.frameConcurrency,
                                                    Self.megapixels(advice.thresholdPixels))
        }

        return intro + "\n\n" + localized("ui.keypoint_no_change_needed", frames, ram)
    }

    private var presetRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.presets, id: \.divisor) { preset in
                VStack(alignment: .leading, spacing: 1) {
                    Toggle(isOn: selection(of: preset.divisor)) {
                        HStack(spacing: 8) {
                            Text(preset.name)
                              .font(.title3)
                              .foregroundColor(.white)
                            Text(Self.format(preset.divisor))
                              .font(.title3)
                              .foregroundColor(.white)
                              .opacity(0.6)
                            if isRecommended(preset.divisor) {
                                Text(localized("ui.recommended"))
                                  .font(.caption)
                                  .foregroundColor(.white)
                                  .padding(.horizontal, 6)
                                  .padding(.vertical, 1)
                                  .background(
                                    Capsule().fill(Color.blue.opacity(0.7))
                                  )
                            }
                        }
                    }
                      .toggleStyle(.checkbox)
                    Text(preset.blurb)
                      .font(.caption)
                      .foregroundColor(.white)
                      .opacity(0.7)
                      .padding(.leading, 20)
                      .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var customRow: some View {
        HStack(spacing: 8) {
            Text(localized("ui.or_use"))
              .font(.title3)
              .foregroundColor(.white)
              .opacity(0.8)
            TextField("", text: $customText)
              .focused($customFocused)
              .frame(width: 70)
              .cursor(.arrow)
              .onSubmit { applyCustomTextIfValid() }
            Text(localized("ui.any_number_from_1_to_8_1_is_full_size_2_is"))
              .font(.caption)
              .foregroundColor(.white)
              .opacity(0.6)
            Spacer()
        }
    }

    private var tooHighWarning: some View {
        Text(localized("ui.keypoint_too_high", Self.format(divisor)))
          .font(.body)
          .foregroundColor(.yellow)
          .fixedSize(horizontal: false, vertical: true)
    }

    /// A checkbox per preset, exclusive: checking one selects it, unchecking the checked
    /// one is ignored. Nothing is checked when a custom value is in effect, which is
    /// truthful — none of the three is what will run.
    private func selection(of value: Double) -> Binding<Bool> {
        Binding(
          get: { matches(value) },
          set: { isOn in
              if isOn { viewModel.alignmentKeypointDetectionDivisor = value }
          }
        )
    }

    /// Compared with a tolerance because `Config` quantizes the divisor to two decimals
    /// for the keypoint filenames, so a value that round-tripped through disk is only
    /// equal to the preset to that precision.
    private func matches(_ value: Double) -> Bool { abs(divisor - value) < 0.005 }

    private func isRecommended(_ value: Double) -> Bool {
        guard let advice, advice.reduceRecommended else { return false }
        return abs(advice.recommendedDivisor - value) < 0.005
    }

    /// The default, applied once when this prompt first appears.
    ///
    /// Only overrides a divisor still sitting at full resolution. Someone who already set
    /// a value in Advanced settings, or is reopening a sequence whose config carries one,
    /// keeps it — and gets this section expanded so they can see what it is rather than
    /// having it hidden behind a collapsed title.
    private func applyAdviceOnce() {
        guard !hasAppliedAdvice else { return }
        hasAppliedAdvice = true

        if let advice, advice.reduceRecommended, divisor <= 1.0 {
            viewModel.alignmentKeypointDetectionDivisor = advice.recommendedDivisor
            Log.i("frames are \(Self.megapixels(advice.imagePixels))MP against a "
                + "\(Self.megapixels(advice.thresholdPixels))MP full resolution limit on "
                + "this machine (\(advice.fullResolutionConcurrency) of "
                + "\(advice.frameConcurrency) keypoint ops fit), defaulting the keypoint "
                + "divisor to \(advice.recommendedDivisor)")
        }

        customText = Self.format(divisor)
        isExpanded = advice?.reduceRecommended == true || divisor > 1.0
    }

    /// Applies the field on every keystroke rather than on commit.
    ///
    /// Start Processing is right below this field, and a value typed but not committed
    /// would be silently dropped when the button takes focus. Every prefix of a number
    /// being typed is itself a valid number, so applying continuously costs nothing.
    private func applyCustomTextIfValid() {
        let filtered = customText.filter { $0.isNumber || $0 == "." }
        guard let value = Double(filtered),
              value >= 1.0,
              value < Self.maxDivisor
        else { return }
        if abs(value - divisor) >= 0.0001 {
            viewModel.alignmentKeypointDetectionDivisor = value
        }
    }

    /// "1", "1.5", "1.75" — no trailing zeros, because this text goes in a field the user
    /// then edits.
    private static func format(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", value)
    }

    private static func megapixels(_ pixels: Int) -> String {
        String(format: "%.1f", Double(pixels) / 1_000_000)
    }

    /// The machine's memory, as someone would say it out loud.
    private static var memoryDescription: String {
        let gb = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        return "\(gb)GB"
    }
}
