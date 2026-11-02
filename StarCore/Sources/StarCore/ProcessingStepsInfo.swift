import Foundation

/// What the info dialog beside the Processing Frames "Steps" heading says: an opening that
/// names the kind of video and the processing mode, then one entry per step the panel is
/// showing — what it does, and which earlier step's results it relies on and why.
///
/// A pure function of what the panel already knows, so the filtering (the dialog must never
/// list a step the panel does not show) and the wording can be tested without a view.  The
/// Kotlin twin is `ProcessingStepsInfo` in star-desktop's `domain`.
public struct ProcessingStepsInfo: Equatable, Sendable {

    /// One step as the dialog describes it.
    public struct Entry: Equatable, Identifiable, Sendable {
        /// The step's `OperationType.rawValue`, or `"extraction"` for the frame extraction row.
        public let id: String
        public let name: String
        /// What the step does.
        public let what: String
        /// Which earlier step's results it relies on, and why.
        public let needs: String
    }

    /// "Star is processing a {moving|static} video in the {mode} processing mode."
    public let intro: String
    /// "The following steps are used to process your video."
    public let subtitle: String
    /// Frame extraction first when the panel shows that row, then exactly the steps given, in the given order.
    public let entries: [Entry]

    /// - Parameters:
    ///   - cameraMoving: whether the camera moved during the sequence.
    ///   - cleanMethod: the run's processing mode.
    ///   - steps: the steps the panel draws, in its order.  Types the panel has no row for are skipped.
    ///   - showsExtraction: whether the panel draws the frame extraction row.
    public static func make(
      cameraMoving: Bool,
      cleanMethod: CleanMethod,
      steps: [OperationType],
      showsExtraction: Bool
    ) -> ProcessingStepsInfo {
        var entries: [Entry] = []
        if showsExtraction {
            entries.append(Entry(id: "extraction",
                                 name: localized("ui.processing_step_extracting_video"),
                                 what: localized("ui.steps_info.extraction.what"),
                                 needs: localized("ui.steps_info.needs.extraction")))
        }
        for type in steps where !type.stepNeeds.isEmpty {
            entries.append(Entry(id: type.rawValue,
                                 name: type.stepName,
                                 what: type.stepHelp.components(separatedBy: "\n\n").first ?? type.stepHelp,
                                 needs: type.stepNeeds))
        }
        return ProcessingStepsInfo(
          intro: localized(cameraMoving ? "ui.steps_info_intro_moving" : "ui.steps_info_intro_static",
                           modeName(cleanMethod)),
          subtitle: localized("ui.steps_info_subtitle"),
          entries: entries)
    }

    /// The same three names the grid's right panel gives the modes.
    static func modeName(_ cleanMethod: CleanMethod) -> String {
        switch cleanMethod {
        case .automatic(let useOutliers): localized(useOutliers ? "ui.auto_selective" : "ui.automatic")
        case .selective:                  localized("ui.selective")
        }
    }
}

extension OperationType {
    /// Which earlier step's results this step relies on, and why: the dependency the graph
    /// builder wires (`FrameGraphBuilder`) put into words.  Empty for the types the processing
    /// modal has no row for.
    public var stepNeeds: String {
        switch self {
        case .horizon:          localized("ui.steps_info.needs.horizon")
        case .mergedHorizon:    localized("ui.steps_info.needs.merged_horizon")
        case .starKeypoints:    localized("ui.steps_info.needs.star_keypoints")
        case .earthKeypoints:   localized("ui.steps_info.needs.earth_keypoints")
        case .starHomography:   localized("ui.steps_info.needs.star_alignment")
        case .earthHomography:  localized("ui.steps_info.needs.earth_alignment")
        case .horizonConsensus: localized("ui.steps_info.needs.horizon_consensus")
        case .outliers:         localized("ui.steps_info.needs.outliers")
        case .merge:            localized("ui.steps_info.needs.merged")
        default:                ""
        }
    }
}
