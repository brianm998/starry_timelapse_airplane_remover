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
    /// The opposite of cleaning: keeps only what moved.  Each pixel is `original − aligned
    /// reference` per channel, clipped at 0, so static stars and static ground go to black and
    /// airplanes, satellites and meteors keep their colour.  The aligned reference is the star
    /// alignment in the sky and the earth alignment on the ground, so one image covers the whole
    /// frame; with horizon detection off it is the star alignment alone.  Replaces the earlier
    /// separate dirty sky and dirty earth methods, whose saved spellings still decode as this.
    case dirty

    public var id: Self { self }

    // Codable is written by hand only so that `dirtySky` and `dirtyEarth`, which a saved config.json
    // or per-frame override may still hold, load as `.dirty`.  The format is otherwise the
    // synthesised one (`{"automatic":{"_0":true}}`, `{"selective":{}}`, `{"dirty":{}}`).
    private enum CodingKeys: String, CodingKey {
        case automatic, selective, dirty, dirtySky, dirtyEarth
    }
    private enum AutomaticCodingKeys: String, CodingKey { case _0 }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.automatic) {
            let inner = try container.nestedContainer(keyedBy: AutomaticCodingKeys.self, forKey: .automatic)
            self = .automatic(try inner.decode(Bool.self, forKey: ._0))
        } else if container.contains(.selective) {
            self = .selective
        } else if container.contains(.dirty) || container.contains(.dirtySky) || container.contains(.dirtyEarth) {
            self = .dirty
        } else {
            throw DecodingError.dataCorrupted(.init(
              codingPath: decoder.codingPath,
              debugDescription: "Unknown clean method"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic(let selective):
            var inner = container.nestedContainer(keyedBy: AutomaticCodingKeys.self, forKey: .automatic)
            try inner.encode(selective, forKey: ._0)
        case .selective:
            _ = container.nestedContainer(keyedBy: AutomaticCodingKeys.self, forKey: .selective)
        case .dirty:
            _ = container.nestedContainer(keyedBy: AutomaticCodingKeys.self, forKey: .dirty)
        }
    }

    public var usesOutliers: Bool {
        switch self {
        case .automatic(let selective):
            selective
        case .selective:
            true
        case .dirty:
            // keep every bad signal: no outlier or blob detection at all
            false
        }
    }

    /// True for the dirty methods, which write a subtraction rather than a cleaned frame.
    public var isDirty: Bool {
        switch self {
        case .dirty: true
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
        case .dirty:
            // the preservation mode is for Automatic only; a dirty method has no use for it
            self = .dirty
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
    case dirty

    public var id: Self { self }

    public var titleText: String {
        switch self {
        case .automatic:
            localized("ui.automatic")
        case .selective:
            localized("ui.selective")
        case .dirty:
            localized("ui.dirty")
        }
    }

    /// The choice a clean method is shown as (the inverse of `CleanMethod.init(highLevelCleanMethod:autoPreservationMode:)`
    /// for everything but the preservation mode).
    public init(_ method: CleanMethod) {
        switch method {
        case .automatic: self = .automatic
        case .selective: self = .selective
        case .dirty: self = .dirty
        }
    }

    /// Whether the "Selective Auto Clean" question applies: only Automatic asks it.  Selective always uses outliers, and the dirty
    /// methods never do, so for both the row is switched off.
    public var usesAutoPreservation: Bool {
        switch self {
        case .automatic: true
        case .selective, .dirty: false
        }
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
        case .dirty:
            localized("ui.clean_method_tip.dirty")
        }
    }

    public var descriptionText: String {
        switch self {
        case .automatic:
            localized("ui.mode_desc_automatic")
        case .selective:
            localized("ui.mode_desc_selective")
        case .dirty:
            localized("ui.mode_desc_dirty")
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
