import SwiftUI
import StarCore
import logging

/// What the cleanup dialog's one-line "Speed vs. Sharpness" row says is in effect, and the
/// button that opens the full choice (`KeypointDivisorStartupView`) in a sheet.
///
/// Kept no taller than the 21pt line of text beside it: this dialog is the one that is too
/// tall for small screens, and on a 768pt display (a hosted runner) a few points more push
/// the Back button into the Dock's zone, where a click is lost.
///
/// The value is the label from `KeypointDivisorStartupView.summaryLabel`: a preset's number
/// and name, or the bare number for any other value.
struct KeypointDivisorSummaryRow: View {
    let divisor: Double
    let onUpdate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(localized("ui.speed_vs_sharpness"))
              .font(.title2)
              .foregroundColor(.white)
            Text(KeypointDivisorStartupView.summaryLabel(divisor))
              .font(.title3)
              .foregroundColor(.white)
              .opacity(0.7)
              .accessibilityIdentifier("startup.removal.speed.value")
            Spacer()
            Button(action: onUpdate) {
                Text(localized("ui.update"))
                  .font(.title3)
                  .foregroundColor(.white)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 1)
                  .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.7)))
            }
              .buttonStyle(PlainButtonStyle())
              .accessibilityIdentifier("startup.removal.speed.update")
        }
          .frame(maxWidth: 640)
    }
}

/// The value the Speed vs. Sharpness sheet edits: a draft of `original`, the value the sheet
/// opened with. Nothing reaches the view model until `committed` is applied (Update);
/// `cancelled` is what Cancel leaves in place.
struct KeypointDivisorDraft {
    let original: Double
    private(set) var current: Double

    init(original: Double) {
        self.original = original
        self.current = original
    }

    /// A preset picked.
    mutating func choose(_ value: Double) { current = value }

    /// The custom field's text, applied on every keystroke: text that is not (yet) a value
    /// leaves the draft alone.
    mutating func typed(_ text: String) {
        if let value = KeypointDivisorStartupView.parse(text) { current = value }
    }

    /// What Update keeps: the draft, a typed custom value included.
    var committed: Double { current }

    /// What Cancel keeps.
    var cancelled: Double { original }
}

/// The keypoint divisor, offered in the startup flow instead of only in Advanced settings.
///
/// It is the one setting on this machine that decides whether a large sequence runs at a
/// sensible speed or crawls, and it was three sheets deep — so it is here, in the last
/// startup prompt, on the way to Start Processing.
///
/// The cleanup dialog shows a one-line `KeypointDivisorSummaryRow`; this is the sheet its
/// Update button opens. It edits a draft: Update hands the draft to `onUpdate`, Cancel hands
/// nothing over, so the value stays as it was when the sheet opened. The explanation and the
/// "Recommended" badge come from `Config.keypointDivisorAdvice(physicalMemory:)` — see there
/// for where the boundary is and why.
///
/// Deliberately free of the words keypoint, homography, SIFT and descriptor: someone who
/// just wants their video cleaned up has to be able to make this choice. The Advanced
/// panel's version of the same setting explains the mechanism for those who want it.
struct KeypointDivisorStartupView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let onCancel: () -> Void
    let onUpdate: (Double) -> Void

    /// The value being edited. Seeded in `init` with the value the sheet opened with.
    @State private var draft: KeypointDivisorDraft

    /// Text of the free-form field. Kept separate from the divisor rather than bound to
    /// it, because a value being typed goes through states the divisor should not be
    /// pushed into ("1.50" would be reformatted to "1.5" under the cursor).
    @State private var customText: String
    @FocusState private var customFocused: Bool

    init(initial: Double, onCancel: @escaping () -> Void, onUpdate: @escaping (Double) -> Void) {
        self.onCancel = onCancel
        self.onUpdate = onUpdate
        _draft = State(initialValue: KeypointDivisorDraft(original: initial))
        _customText = State(initialValue: Self.format(initial))
    }

    struct Preset {
        let divisor: Double
        let name: String
        let blurb: String
    }

    /// The three offered values. 1.5 comes from `Config` rather than being written here so
    /// the recommendation and the preset cannot drift apart.
    static var presets: [Preset] { [
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
    static let tooHighDivisor: Double = 4.0

    /// The largest value the field will accept at all — past here it is not a trade any
    /// more, it is a typo. Inclusive, matching the `maxValue: 8` this same setting already
    /// has in the Advanced panel's `EditableNumberView`, so a value entered here is one
    /// that panel will also accept.
    static let maxDivisor: Double = 8.0

    private var divisor: Double { draft.current }

    private var advice: Config.KeypointDivisorAdvice? {
        viewModel.config.config()
          .keypointDivisorAdvice(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localized("ui.speed_vs_sharpness"))
              .font(.title2)
              .foregroundColor(.white)
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
            Space(height: 20)
            buttons
        }
          .frame(maxWidth: 640, alignment: .leading)
          .padding(24)
          .onChange(of: customText) { applyCustomTextIfValid() }
          .onChange(of: divisor) {
              // Resync the field when a preset moved the value, but never while it is
              // being typed into — that would rewrite the text under the cursor.
              if !customFocused { customText = Self.format(divisor) }
          }
    }

    /// Cancel on the left, Update on the right. Return is Update while this sheet is up, so it
    /// does not reach Start Processing underneath.
    private var buttons: some View {
        HStack {
            Button(action: onCancel) {
                Text(localized("ui.cancel"))
                  .font(.title3)
                  .foregroundColor(.black)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(RoundedRectangle(cornerRadius: 16).fill(.white))
            }
              .buttonStyle(PlainButtonStyle())
              .accessibilityIdentifier("startup.speed.cancel")
              .keyboardShortcut(.cancelAction)
            Spacer()
            Button { onUpdate(draft.committed) } label: {
                Text(localized("ui.update"))
                  .font(.title3)
                  .foregroundColor(.white)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(RoundedRectangle(cornerRadius: 16).fill(Color.blue.opacity(0.7)))
            }
              .buttonStyle(PlainButtonStyle())
              .accessibilityIdentifier("startup.speed.update")
              .keyboardShortcut(.defaultAction)
        }
    }

    /// What the cleanup dialog's summary row says is in effect: "1 — Best quality",
    /// "1.5 — Best balance" or "2 — Fastest" for a preset, and the bare number for any other
    /// value — none of the three is what will run, so none is named.
    static func summaryLabel(_ divisor: Double) -> String {
        guard let preset = presets.first(where: { abs(divisor - $0.divisor) < 0.005 }) else {
            return format(divisor)
        }
        return "\(format(preset.divisor)) \u{2014} \(preset.name)"
    }

    /// What the field holds as a value, or nil while it is not one: the digits and points of
    /// `text`, read as a number from 1 to `maxDivisor`.
    static func parse(_ text: String) -> Double? {
        let filtered = text.filter { $0.isNumber || $0 == "." }
        guard let value = Double(filtered), value >= 1.0, value <= maxDivisor else { return nil }
        return value
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
              if isOn { draft.choose(value) }
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

    /// Applies the field to the draft on every keystroke rather than on commit, so a value
    /// typed but not committed is still what Update keeps. Every prefix of a number being
    /// typed is itself a valid number, so applying continuously costs nothing.
    private func applyCustomTextIfValid() {
        draft.typed(customText)
    }

    /// "1", "1.5", "1.75" — no trailing zeros, because this text goes in a field the user
    /// then edits.
    static func format(_ value: Double) -> String {
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
