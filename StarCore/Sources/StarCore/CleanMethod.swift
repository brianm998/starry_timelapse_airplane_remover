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

    public var id: Self { self }
    
    public var usesOutliers: Bool {
        switch self {
        case .automatic(let selective):
            selective
        case .selective:
            true
        }
    }

    public init(
      highLevelCleanMethod: HighLevelCleanMethod,
      autoPreservationMode: AutoPreservationMode
    ) {
        switch highLevelCleanMethod {
        case .selective:
            self = .selective
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

    public var id: Self { self }

    public var titleText: String {
        switch self {
        case .automatic:
            "Automatic"
        case .selective:
            "Selective"
        }
    }

    public static let topTitle = "Clean Mode:"
    
    public var helpText: String {
        switch self {
        case .automatic:
            "Fully automatic removal of airplanes/satellites; replaces each frame with a clean median composite."
        case .selective:
            "Selective Clean – Detects only streak-like outliers and lets you decide which to remove; good for clouds or when you want control."
        }
    }

    public var descriptionText: String {
        switch self {
        case .automatic:
            "This mode automatically builds a clean “best version” of every frame using neighboring frames. It removes streaks extremely well when skies are clear. It requires almost no user input and is faster to use, but it can struggle around dawn/dusk and may distort fast-moving clouds."
        case .selective:
            "This mode compares each original frame to a clean reference frame and highlights only the differences that look like airplane or satellite streaks. You can review and approve these changes. It works better when clouds are present or when you want to keep certain objects (like meteors). It takes more interaction but gives you finer control."
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

    public static let topTitle = "Selective Auto Clean:"
    
    public var helpText: String {
        switch self {
        case .yes:
            "Apply Selective Clean after Auto Clean to keep important objects from the original frame."
        case .no:
            "Use pure Auto Clean with full automatic replacement."
        }
    }

    public var titleText: String {
        self.rawValue
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
            "After Auto Clean creates a streak-free frame, Selective Clean can be run in reverse to restore specific bright events—such as meteors or flares—from the original footage. This lets you keep rare celestial events while still removing planes and satellites."
        case .no:
            "The processor will use the fully automatic method only. This gives the cleanest sky possible but removes all bright moving objects, including meteors."
        }
    }
}
