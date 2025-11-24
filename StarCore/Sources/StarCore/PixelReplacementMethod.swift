import Foundation

// An enum that determines our top level processing mode

public enum PixelReplacementMethod: Identifiable,
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
