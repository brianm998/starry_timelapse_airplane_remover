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
                "Auto Clean"
            } else {
                "Selective Auto Clean"
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
}
