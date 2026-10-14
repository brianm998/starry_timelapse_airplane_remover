import Foundation
import StarCore
import StarDaemonMessages

/// The blob processing steps of a detection type, in the form the Blob Processing window lists them (macOS `BlobProcessingView`), and the changes
/// that window makes to the custom detection type.
enum BlobSteps {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case noSuchStep(Int)
        case noSuchParameter(step: Int, name: String)
        case copyFromItself

        var description: String {
            switch self {
            case .noSuchStep(let index):
                return "the custom detection type has no step \(index)"
            case .noSuchParameter(let step, let name):
                return "step \(step) has no parameter '\(name)'"
            case .copyFromItself:
                return "the custom detection type cannot be copied from itself"
            }
        }
    }

    // MARK: - listing

    /// The steps of [type] as the processor holds them. `processor` is given for a test; it is the type's own otherwise.
    static func response(for type: DetectionType, processor given: AbstractBlobProcessor? = nil) -> Star_V1_BlobStepsResponse {
        let processor = given ?? type.blobProcessor
        let custom = processor as? CustomBlobProcessor
        var response = Star_V1_BlobStepsResponse()
        response.detectionType = Mapping.protoDetectionType(type)
        response.steps = processor.steps.enumerated().map { index, step in
            describe(step, disabled: custom?.isDisabled(atIndex: index) ?? false)
        }
        response.description_p = localized("ui.detection_type_desc.\(type.rawValue)")
        response.editable = type == .custom
        return response
    }

    static func describe(_ step: BlobProcessingType, disabled: Bool = false) -> Star_V1_BlobStep {
        var out = Star_V1_BlobStep()
        switch step {
        case .findBlobs(let args):
            out = configurable("findBlobs", "ui.initial_blob_detection", "ui.initial_blob_detection_desc", args)
            // the first step is what every other one works on: it cannot be skipped
            out.canDisable = false
        case .smallBlobRemover(let args):
            out = configurable("smallBlobRemover", "ui.small_blob_remover", "ui.small_blob_remover_desc", args)
        case .linearBlobConnector(let args):
            out = configurable("linearBlobConnector", "ui.linear_blob_connector", "ui.linear_blob_connector_desc", args)
        case .linearBlobExtender(let args):
            out = configurable("linearBlobExtender", "ui.linear_blob_extender", "ui.linear_blob_extender_desc", args)
        case .blobLineTrim(let args):
            out = configurable("blobLineTrim", "ui.blob_line_trim", "ui.blob_line_trim_desc", args)
        case .houghLineMatrixBlobConnector(let args):
            out = configurable("houghLineMatrixBlobConnector", "ui.hough_line_matrix_blob_connector", "ui.hough_line_matrix_blob_connector_desc", args)
        case .applyUserSlices:
            out.kind = "applyUserSlices"
            out.title = localized("ui.apply_user_slices")
            out.description_p = localized("ui.apply_any_existing_user_slices_to_blobs")
        case .compactBlobIds:
            out.kind = "compactBlobIds"
            out.title = localized("ui.compact_blob_ids")
            out.description_p = localized("ui.re_id_blobs_to_free_up_id_space")
        case .blobDupeCheck(let name):
            out.kind = "blobDupeCheck"
            out.title = localized("ui.blob_dupe_check")
            out.description_p = localized("ui.duplicate_blob_step", name)
        case .save(let mode):
            out.kind = "save"
            out.title = localized("ui.save_image")
            out.description_p = localized("view_mode.\(mode.rawValue)")
        case .frameState(let state):
            out.kind = "frameState"
            out.title = localized("ui.set_frame_processing_state")
            out.description_p = state.message
        }
        out.disabled = out.canDisable && disabled
        return out
    }

    /// A step with parameters: what it is called, what it does, and each parameter with its value as it is now.
    private static func configurable<A: Argable>(_ kind: String, _ titleKey: String, _ descriptionKey: String, _ args: A) -> Star_V1_BlobStep
        where A.Types: CaseIterable
    {
        var out = Star_V1_BlobStep()
        out.kind = kind
        out.title = localized(titleKey)
        out.description_p = localized(descriptionKey)
        out.args = A.Types.allCases.map { type in
            var arg = Star_V1_BlobStepArg()
            arg.name = "\(type)"
            if let value = args.value(for: type) {
                arg.valuePresent = true
                arg.value = value
            }
            arg.isInteger = args.isInteger(type)
            arg.isOptional = args.isOptional(type)
            arg.description_p = args.description(for: type)
            return arg
        }
        out.canDisable = true
        return out
    }

    // MARK: - changing the custom type

    /// Make the change a request asks for to [processor] (the custom one), and return its steps as they now are.
    static func apply(_ request: Star_V1_SetCustomBlobStepsRequest, to processor: CustomBlobProcessor) throws -> Star_V1_BlobStepsResponse {
        switch request.change {
        case .copyFrom(let source):
            let type = Mapping.detectionType(from: source)
            guard type != .custom else { throw Failure.copyFromItself }
            processor.copySteps(from: type.blobProcessor)
        case .arg(let change):
            try setParameter(change, on: processor)
        case .disabled(let change):
            guard processor.steps.indices.contains(Int(change.stepIndex)) else { throw Failure.noSuchStep(Int(change.stepIndex)) }
            processor.setDisabled(change.disabled, atIndex: Int(change.stepIndex))
        case nil:
            break
        }
        return response(for: .custom, processor: processor)
    }

    private static func setParameter(_ change: Star_V1_BlobStepArgChange, on processor: CustomBlobProcessor) throws {
        let index = Int(change.stepIndex)
        guard processor.steps.indices.contains(index) else { throw Failure.noSuchStep(index) }
        switch processor.steps[index] {
        case .findBlobs(let args):                    try update(args, change, processor)
        case .smallBlobRemover(let args):             try update(args, change, processor)
        case .linearBlobConnector(let args):          try update(args, change, processor)
        case .linearBlobExtender(let args):           try update(args, change, processor)
        case .blobLineTrim(let args):                 try update(args, change, processor)
        case .houghLineMatrixBlobConnector(let args): try update(args, change, processor)
        case .applyUserSlices, .compactBlobIds, .blobDupeCheck, .save, .frameState:
            throw Failure.noSuchParameter(step: index, name: change.argName)
        }
    }

    /// The parameter by its name, set the way the window sets it: an integer one from the number rounded, any other as it is.
    private static func update<A: Argable>(_ args: A, _ change: Star_V1_BlobStepArgChange, _ processor: CustomBlobProcessor) throws
        where A.Types: CaseIterable
    {
        let index = Int(change.stepIndex)
        guard let type = A.Types.allCases.first(where: { "\($0)" == change.argName }) else {
            throw Failure.noSuchParameter(step: index, name: change.argName)
        }
        if args.isInteger(type) {
            processor.intUpdate(args, type, Int(change.value.rounded()), index)
        } else {
            processor.doubleUpdate(args, type, change.value, index)
        }
    }
}
