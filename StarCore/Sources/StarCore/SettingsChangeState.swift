import Foundation

/// Whether the settings sheet is describing a change that contradicts work already on
/// disk — the thing that turns Process Now into Update and puts the red line under the
/// heading.
///
/// A value rather than a condition spelled out in the view, because the rule has two
/// halves that are easy to get backwards.  A change with nothing finished behind it is the
/// ordinary case this whole view was built for and must stay silent; work finished with no
/// change behind it is a sequence being resumed, which is also ordinary and also silent.
/// Only both together are worth interrupting for.
public enum SettingsChangeState {

    /// - Parameters:
    ///   - changedStages: what the settings changed in this settings session would
    ///     invalidate, from `ArtifactInputs`.  Empty for the concurrency and memory knobs,
    ///     which change how the work is done rather than what comes out.
    ///   - openedSequenceWasUntouched: whether the survey taken when this sequence was
    ///     opened found nothing done to it, or nil where no survey was taken — a sequence
    ///     set up for the first time in this session, which by definition has nothing on
    ///     disk from before.
    public static func contradictsFinishedWork(
      isProcessingFrames: Bool,
      completeFrameCount: Int,
      userModifiedFrameCount: Int,
      openedSequenceWasUntouched: Bool?,
      changedStages: Set<ArtifactStage>
    ) -> Bool {
        guard !changedStages.isEmpty else { return false }

        // A live run counts before its first frame is written: the horizon masks and
        // keypoint sets it has already built were built under the settings as they were,
        // and those are exactly what a change throws away.
        if isProcessingFrames { return true }

        if completeFrameCount > 0 { return true }
        if userModifiedFrameCount > 0 { return true }
        return openedSequenceWasUntouched == false
    }
}
