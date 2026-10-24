import Foundation

/// How far along one processing step is, over the whole of what that step has to cover.
///
/// The three live counts are operations rather than frames, because that is what there is
/// to count: `FrameGraphBuilder` builds one op per frame for most steps, but it skips the
/// frames whose artifact is already on disk, and the static tripod case merges every
/// horizon in a single op.  Measuring a bar on those alone measures the wrong job the
/// moment a run is resumed — a sequence half written builds ops for the half that is left,
/// and a bar over them starts at zero as though nothing had ever been done.  `alreadyDone`
/// is the rest of it, reported by the builder, and it belongs at the finished end.
public struct ProcessingStepProgress: Identifiable, Equatable, Sendable {
    public let type: OperationType
    public let queued: Int
    public let running: Int
    public let done: Int

    /// Frames of this step that were finished before the run started, so the graph built
    /// no operation for them.  Part of the bar, at the done end: a sequence resumed half
    /// way through is half finished, not starting from nothing.
    public let alreadyDone: Int

    public init(type: OperationType, queued: Int, running: Int, done: Int, alreadyDone: Int = 0) {
        self.type = type
        self.queued = queued
        self.running = running
        self.done = done
        self.alreadyDone = alreadyDone
    }

    public var id: OperationType { type }

    /// Every frame this step covers, whoever did it and whenever.
    public var total: Int { alreadyDone + queued + running + done }

    /// Frames of this step that are finished, this run's and any earlier run's alike.
    public var completed: Int { alreadyDone + done }

    /// A step with nothing to it at all: no operations, and nothing already on disk that
    /// they would have produced.  Not a step this run is taking in any sense.
    public var hasWork: Bool { total > 0 }

    public var doneFraction: Double { fraction(of: completed) }
    public var runningFraction: Double { fraction(of: running) }

    private func fraction(of count: Int) -> Double {
        total > 0 ? Double(count) / Double(total) : 0
    }
}

/// The steps the processing modal draws, and how it reads their progress out of
/// `FrameGraphViewModel`.
///
/// Plain functions over plain values rather than anything the view owns, so the arithmetic
/// below — which is the part that can be wrong without looking wrong — is testable.
public enum ProcessingSteps {

    /// The steps this configuration will take, in the order the modal stacks them: horizon
    /// work first, then keypoints, then alignment, then outlier detection, then the merge
    /// that consumes all of it.
    ///
    /// The conditions are `FrameGraphBuilder.build`'s own, spelled the same way, because a
    /// row for a step that will never run is worse than no row: it sits at zero for the
    /// whole run and reads as something stuck.  Two of them are easy to get wrong from the
    /// gui side — earth work needs the camera to have been moving as well as the setting to
    /// be on, since a fixed tripod has nothing to align the ground against, and a painted
    /// static reference horizon replaces horizon detection and its merge outright.
    ///
    /// Deliberately not `OperationType.allCases`: `preview` is thumbnail work that has
    /// nothing to do with a processing run, and `alignmentValidation` is an internal stage
    /// this display does not break out.  `horizonConsensus` is one op for the whole
    /// sequence, like a static tripod's horizon merge, and has a row of its own.
    public static func types(
      horizonDetectionEnabled: Bool,
      hasStaticReferenceHorizon: Bool,
      cameraWasMoving: Bool,
      allowEarthAlignment: Bool,
      usesOutliers: Bool,
      usesHorizonConsensus: Bool = false
    ) -> [OperationType] {
        let paintedStaticReference = hasStaticReferenceHorizon && !cameraWasMoving
        let detectsHorizons = horizonDetectionEnabled && !paintedStaticReference
        let processesEarth = horizonDetectionEnabled && allowEarthAlignment && cameraWasMoving

        var types: [OperationType] = []
        if detectsHorizons {
            types.append(.horizon)
            types.append(.mergedHorizon)
        }
        types.append(.starKeypoints)
        if processesEarth { types.append(.earthKeypoints) }
        types.append(.starHomography)
        if processesEarth { types.append(.earthHomography) }
        // Its own row, after the alignment it is carried along and before the outlier
        // subtraction and the merge that composite with it.  A sequence with painted
        // references skips it; the built graph then has no op for it and the row is dropped.
        if processesEarth && usesHorizonConsensus { types.append(.horizonConsensus) }
        if usesOutliers { types.append(.outliers) }
        types.append(.merge)
        return types
    }

    /// The steps a run under `config` will take.
    public static func types(for config: Config) -> [OperationType] {
        types(horizonDetectionEnabled: config.horizonDetectionEnabled,
              hasStaticReferenceHorizon: config.hasStaticReferenceHorizon,
              cameraWasMoving: config.tripodHeadWasMoving,
              allowEarthAlignment: config.allowEarthAlignment,
              usesOutliers: config.cleanMethod.usesOutliers,
              usesHorizonConsensus: HorizonConsensus.applies(to: config))
    }

    /// The rows worth drawing, out of the steps this configuration can take.
    ///
    /// A step can be one this run does not need even though the configuration allows it —
    /// every artifact it would produce is already on disk, so the builder gives it no
    /// operations at all.  Those are dropped, but only once `graphIsBuilt`: while the plan
    /// is still being assembled every step has no operations yet, and filtering then would
    /// empty the panel and then pop the rows in one at a time as the builder reached them.
    public static func visible(
      _ steps: [ProcessingStepProgress],
      graphIsBuilt: Bool
    ) -> [ProcessingStepProgress] {
        graphIsBuilt ? steps.filter(\.hasWork) : steps
    }

    /// Progress for each of `types`, measured from `baseline`.
    ///
    /// `FrameGraphViewModel`'s counters only reset when the sequence is closed, so by the
    /// second run of a session they already hold every op the first run finished.  Taking a
    /// baseline when a run starts is what keeps the bars showing *this* run rather than
    /// filling in most of the way the moment they appear.
    ///
    /// The counters move a count between states rather than recounting, so `queued +
    /// running + done` for a type only ever grows: subtracting the baseline from it gives
    /// the ops this run created.  The clamping below matters only if a previous run's ops
    /// were still in flight when this one started, which the gui does not allow — it is
    /// there so that case reads as odd numbers rather than as a negative width.
    public static func progress(
      for types: [OperationType],
      counts: [OperationType: [OperationState: UInt]],
      since baseline: [OperationType: [OperationState: UInt]] = [:],
      alreadyDone: [OperationType: UInt] = [:]
    ) -> [ProcessingStepProgress] {
        types.map { type in
            let now = counts[type] ?? [:]
            let base = baseline[type] ?? [:]

            func count(_ states: [OperationState: UInt], _ state: OperationState) -> Int {
                Int(states[state] ?? 0)
            }
            func total(_ states: [OperationState: UInt]) -> Int {
                count(states, .queued) + count(states, .running) + count(states, .done)
            }

            let created = max(0, total(now) - total(base))
            let done = max(0, count(now, .done) - count(base, .done))
            let running = min(count(now, .running), created)
            let all = max(created, done + running)

            return ProcessingStepProgress(
              type: type,
              queued: max(0, all - done - running),
              running: running,
              done: min(done, all),
              alreadyDone: Int(alreadyDone[type] ?? 0)
            )
        }
    }
}

extension OperationType {
    /// What the processing modal labels this step.
    ///
    /// A noun, unlike `UpdatableProgressMonitor`'s `logName`, which is the tail of a cli
    /// progress bar caption ("found horizon") and reads wrong as a row label.  The types
    /// the modal never lists fall back to the raw name; nothing shows those.
    public var stepName: String {
        switch self {
        case .horizon:         localized("ui.horizon")
        case .mergedHorizon:   localized("ui.merged_horizon")
        case .starKeypoints:   localized("ui.star_keypoints")
        case .earthKeypoints:  localized("ui.earth_keypoints")
        case .starHomography:  localized("ui.star_alignment")
        case .earthHomography: localized("ui.earth_alignment")
        case .horizonConsensus: localized("ui.horizon_consensus")
        case .outliers:        localized("ui.outliers")
        case .merge:           localized("ui.merged")
        default:               rawValue
        }
    }

    /// What this step does, how long it tends to take, and why — the tooltip on its row.
    ///
    /// The cost each one describes is not a guess: every op reserves against a multiple of
    /// the working frame recorded in `Config`, and those properties carry the measurements
    /// the wording here is drawn from — `keypointMemoryMultiplier` for why detection is the
    /// step that sets the pace, `horizonMemoryMultiplier` and `horizonReservationFloorMB`
    /// for why horizon detection is nearly flat in frame size, `outlierMemoryMultiplier`
    /// for why outlier cost follows how much is in the frame rather than how big it is.
    /// Check them there if any of this stops being true.
    public var stepHelp: String {
        switch self {
        case .horizon:         localized("ui.step_help.horizon")
        case .mergedHorizon:   localized("ui.step_help.merged_horizon")
        case .starKeypoints:   localized("ui.step_help.star_keypoints")
        case .earthKeypoints:  localized("ui.step_help.earth_keypoints")
        case .starHomography:  localized("ui.step_help.star_alignment")
        case .earthHomography: localized("ui.step_help.earth_alignment")
        case .horizonConsensus: localized("ui.step_help.horizon_consensus")
        case .outliers:        localized("ui.step_help.outliers")
        case .merge:           localized("ui.step_help.merged")
        default:               ""
        }
    }
}

