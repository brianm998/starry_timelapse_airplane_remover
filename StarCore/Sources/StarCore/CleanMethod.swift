import Foundation

// An enum that determines our top level processing mode
// Proto mirror: Star_V1_CleanMethod in daemon/proto/star.proto — keep cases in sync.
public enum CleanMethod: Identifiable,
                         Hashable,
                         Sendable,
                         Codable
{
    case automatic(Bool)
    case selective
    /// The opposite of cleaning, for the sky: keeps only what moved there.  Each sky pixel is
    /// `original − aligned reference` per channel, clipped at 0, so static stars go to black and
    /// airplanes, satellites and meteors keep their colour; the ground is black.  With horizon
    /// detection off there is no ground, so this covers the whole frame.
    case dirtySky
    /// The same for the ground: moved ground pixels keep their colour, static ground goes to
    /// black, the sky is black.  Needs horizon detection (`Config.cleanMethodConflict`).  On a
    /// moving camera, a frame whose ground neighbours cannot be tracked has the original as its
    /// earth reference, so its dirty earth output is (correctly) near-black.
    case dirtyEarth

    public var id: Self { self }
    
    public var usesOutliers: Bool {
        switch self {
        case .automatic(let selective):
            selective
        case .selective:
            true
        case .dirtySky, .dirtyEarth:
            // keep every bad signal: no outlier or blob detection at all
            false
        }
    }

    /// True for the dirty methods, which write a subtraction rather than a cleaned frame.
    public var isDirty: Bool {
        switch self {
        case .dirtySky, .dirtyEarth: true
        case .automatic, .selective: false
        }
    }

    public init(
      highLevelCleanMethod: HighLevelCleanMethod,
      autoPreservationMode: AutoPreservationMode
    ) {
        switch highLevelCleanMethod {
        case .selective:
            self = .selective
        case .dirtySky:
            // the preservation mode is for Automatic only; a dirty method has no use for it
            self = .dirtySky
        case .dirtyEarth:
            self = .dirtyEarth
        case .automatic:
            switch autoPreservationMode {
            case .no:
                self = .automatic(false)
            case .yes:
                self = .automatic(true)
            }
        }
    }
}

public enum HighLevelCleanMethod: InstructionOption,
                                             Sendable,
                                             Codable
{
    case automatic
    case selective
    case dirtySky
    case dirtyEarth

    public var id: Self { self }

    public var titleText: String {
        switch self {
        case .automatic:
            localized("ui.automatic")
        case .selective:
            localized("ui.selective")
        case .dirtySky:
            localized("ui.dirty_sky")
        case .dirtyEarth:
            localized("ui.dirty_earth")
        }
    }

    /// The choice a clean method is shown as (the inverse of `CleanMethod.init(highLevelCleanMethod:autoPreservationMode:)`
    /// for everything but the preservation mode).
    public init(_ method: CleanMethod) {
        switch method {
        case .automatic: self = .automatic
        case .selective: self = .selective
        case .dirtySky: self = .dirtySky
        case .dirtyEarth: self = .dirtyEarth
        }
    }

    /// Whether the "Selective Auto Clean" question applies: only Automatic asks it.  Selective always uses outliers, and the dirty
    /// methods never do, so for both the row is switched off.
    public var usesAutoPreservation: Bool {
        switch self {
        case .automatic: true
        case .selective, .dirtySky, .dirtyEarth: false
        }
    }

    /// Dirty earth keeps only the ground, so it needs a horizon (`Config.cleanMethodConflict` refuses it otherwise).
    public func isAvailable(horizonDetectionEnabled: Bool) -> Bool {
        switch self {
        case .dirtyEarth: horizonDetectionEnabled
        case .automatic, .selective, .dirtySky: true
        }
    }

    /// The tip to show instead of `helpText` when the choice is switched off, or nil when it is on.
    public func unavailableText(horizonDetectionEnabled: Bool) -> String? {
        isAvailable(horizonDetectionEnabled: horizonDetectionEnabled)
          ? nil : localized("ui.clean_method_tip.dirty_earth_needs_horizon")
    }

    /// What the choice becomes when the horizon is switched off: dirty earth cannot stay chosen, so it falls back to Automatic.
    public func coerced(horizonDetectionEnabled: Bool) -> HighLevelCleanMethod {
        isAvailable(horizonDetectionEnabled: horizonDetectionEnabled) ? self : .automatic
    }

    /// The row's heading, from the catalogue: the same "Clean Method" the desktop's settings sheet has, with the colon the other rows' headings carry.
    public static var topTitle: String { localized("ui.clean_method") + ":" }
    
    /// The hover text on the choice and the text under the row's (i), from the catalogue. The desktop's settings sheet reads the same keys
    /// (`gherkin/ui/vectors/constants.json`, `cleanMethod.texts`); these were English paragraphs written here.
    public var helpText: String {
        switch self {
        case .automatic:
            localized("ui.clean_method_tip.automatic")
        case .selective:
            localized("ui.clean_method_tip.selective")
        case .dirtySky:
            localized("ui.clean_method_tip.dirty_sky")
        case .dirtyEarth:
            localized("ui.clean_method_tip.dirty_earth")
        }
    }

    public var descriptionText: String {
        switch self {
        case .automatic:
            localized("ui.mode_desc_automatic")
        case .selective:
            localized("ui.mode_desc_selective")
        case .dirtySky:
            localized("ui.mode_desc_dirty_sky")
        case .dirtyEarth:
            localized("ui.mode_desc_dirty_earth")
        }
    }
}

public protocol InstructionOption: CaseIterable,
                                   Identifiable,
                                   Hashable
  where AllCases: RandomAccessCollection
{
    /// Title used in pickers
    var titleText: String { get }

    /// Inline help text for the picker row
    var helpText: String { get }

    /// Long-form description shown in the info panel
    var descriptionText: String { get }

    static var topTitle: String { get }
}

public enum AutoPreservationMode: String, InstructionOption, Identifiable {
    case yes = "Yes"
    case no = "No"

    public var id: Self { self }

    public static var topTitle: String { localized("ui.selective_auto_clean") }
    
    public var helpText: String {
        switch self {
        case .yes:
            localized("ui.selective_auto_clean_tip.yes")
        case .no:
            localized("ui.selective_auto_clean_tip.no")
        }
    }

    public var titleText: String {
        switch self {
        case .yes: localized("ui.yes")
        case .no: localized("ui.no")
        }
    }

    public var boolValue: Bool {
        switch self {
        case .yes:
            true
        case .no:
            false
        }
    }

    public var descriptionText: String {
        switch self {
        case .yes:
            localized("ui.mode_desc_auto_selective")
        case .no:
            localized("ui.mode_desc_automatic")
        }
    }
}

extension Config {
    /// What `.dirtyEarth` without horizon detection is refused with: with no horizon there is
    /// no ground portion to keep.
    public static var dirtyEarthNeedsHorizonMessage: String {
        localized("cli.errors.dirty_earth_needs_horizon")
    }

    /// Why this config's clean method cannot run, in the user's language, or nil when it can.
    /// The cli asks after its overrides are applied, for a new sequence and a resumed one alike.
    public var cleanMethodConflict: String? {
        if cleanMethod == .dirtyEarth, !horizonDetectionEnabled {
            return Config.dirtyEarthNeedsHorizonMessage
        }
        return nil
    }
}
