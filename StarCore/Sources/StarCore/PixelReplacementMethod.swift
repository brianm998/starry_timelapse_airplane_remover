import Foundation

// An enum that determines our top level processing mode

public enum PixelReplacementMethod: CaseIterable,
                                    Identifiable,
                                    Hashable,
                                    Sendable,
                                    Codable
{
    case automatic(Bool)
    case selective

    public var id: Self { self }

    public static var allCases: [PixelReplacementMethod] {
        [
          .automatic(false),
          .selective
        ]
    }
    
    public var usesOutliers: Bool {
        switch self {
        case .automatic(let selective):
            selective
        case .selective:
            true
        }
    }

    public var titleText: String {
        switch self {
        case .automatic(let selective):
            if selective {
                "Selective Auto Clean"
            } else {
                "Auto Clean"
            }
        case .selective:
            "Selective Clean"
        }
    }
    
    public var helpText: String {
        switch self {
        case .automatic(let selective):
            "Fully automatic removal of airplanes/satellites; replaces each frame with a clean median composite."
        case .selective:
            "Selective Clean – Detects only streak-like outliers and lets you decide which to remove; good for clouds or when you want control."
        }
    }

    public var description: String {
        switch self {
        case .automatic(let selective):
            "This mode automatically builds a clean “best version” of every frame using neighboring frames. It removes streaks extremely well when skies are clear. It requires almost no user input and is faster to use, but it can struggle around dawn/dusk and may distort fast-moving clouds."
        case .selective:
            "This mode compares each original frame to a clean reference frame and highlights only the differences that look like airplane or satellite streaks. You can review and approve these changes. It works better when clouds are present or when you want to keep certain objects (like meteors). It takes more interaction but gives you finer control."
        }
    }

    public func apply(autoPreservationMode: AutoPreservationMode) -> PixelReplacementMethod {
        switch self {
        case .automatic(_):
            switch autoPreservationMode {
            case .yes:
                .automatic(true)
            case .no:
                .automatic(false)
            }
        case .selective:
            self
        }
    }
}
    
public enum AutoPreservationMode: String, CaseIterable, Identifiable {
    case yes = "Yes"
    case no = "No"

    public var id: Self { self }

    public var helpText: String {
        switch self {
        case .yes:
            "Apply Selective Clean after Auto Clean to keep important objects from the original frame."
        case .no:
            "Use pure Auto Clean with full automatic replacement."
        }
    }

    public var description: String {
        switch self {
        case .yes:
            "After Auto Clean creates a streak-free frame, Selective Clean can be run in reverse to restore specific bright events—such as meteors or flares—from the original footage. This lets you keep rare celestial events while still removing planes and satellites."
        case .no:
            "The processor will use the fully automatic method only. This gives the cleanest sky possible but removes all bright moving objects, including meteors."
        }
    }
}
