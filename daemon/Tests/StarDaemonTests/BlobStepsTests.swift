import XCTest
import StarCore
import StarDaemonMessages
@testable import stard

/// H9: the blob processing steps as a client lists them, and the changes it makes to the custom detection type.
final class BlobStepsTests: XCTestCase {
    private var savedHome: String?
    private var home: URL!

    override func setUp() {
        super.setUp()
        StarLocalization.shared.languageOverride = "en"
        // a custom processor keeps its steps in a file in $HOME, which a test must not write into the real one
        savedHome = ProcessInfo.processInfo.environment["HOME"]
        home = FileManager.default.temporaryDirectory.appendingPathComponent("star-blob-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("HOME", home.path, 1)
    }

    override func tearDown() {
        if let savedHome { setenv("HOME", savedHome, 1) } else { unsetenv("HOME") }
        try? FileManager.default.removeItem(at: home)
        StarLocalization.shared.languageOverride = nil
        super.tearDown()
    }

    private func steps(_ type: DetectionType) -> Star_V1_BlobStepsResponse { BlobSteps.response(for: type) }

    private func custom(copying type: DetectionType = .strong) throws -> CustomBlobProcessor {
        let processor = CustomBlobProcessor()
        _ = try BlobSteps.apply(copy(type), to: processor)
        return processor
    }

    private func copy(_ type: DetectionType) -> Star_V1_SetCustomBlobStepsRequest {
        var request = Star_V1_SetCustomBlobStepsRequest()
        request.copyFrom = Mapping.protoDetectionType(type)
        return request
    }

    private func setArg(_ step: Int, _ name: String, _ value: Double) -> Star_V1_SetCustomBlobStepsRequest {
        var change = Star_V1_BlobStepArgChange()
        change.stepIndex = Int32(step); change.argName = name; change.value = value
        var request = Star_V1_SetCustomBlobStepsRequest()
        request.arg = change
        return request
    }

    private func setDisabled(_ step: Int, _ disabled: Bool) -> Star_V1_SetCustomBlobStepsRequest {
        var change = Star_V1_BlobStepDisabledChange()
        change.stepIndex = Int32(step); change.disabled = disabled
        var request = Star_V1_SetCustomBlobStepsRequest()
        request.disabled = change
        return request
    }

    private func index(of kind: String, in response: Star_V1_BlobStepsResponse) throws -> Int {
        try XCTUnwrap(response.steps.firstIndex { $0.kind == kind }, "no \(kind) step")
    }

    // MARK: - listing

    func testEveryDetectionTypeListsItsStepsWithTheirParameters() {
        for type in DetectionType.allCases where type != .custom {
            let response = steps(type)
            XCTAssertEqual(response.steps.count, type.blobProcessor.steps.count, "\(type)")
            XCTAssertFalse(response.editable, "\(type) cannot be changed")
            XCTAssertFalse(response.steps.isEmpty)
            let first = response.steps[0]
            XCTAssertEqual(first.kind, "findBlobs", "\(type) starts with the initial detection")
            XCTAssertFalse(first.canDisable, "the initial detection cannot be skipped")
            XCTAssertEqual(first.args.count, BlobFinder.Args.ArgType.allCases.count)
            XCTAssertTrue(first.args.contains { $0.name == "minPixelIntensity" && $0.valuePresent && $0.isInteger })
            XCTAssertTrue(first.args.contains { $0.name == "startMinContrast" && !$0.isInteger })
        }
    }

    func testTheValuesAreTheProcessorsOwn() throws {
        guard case .findBlobs(let args) = DetectionType.mild.blobProcessor.steps[0] else { return XCTFail("no findBlobs") }
        let listed = steps(.mild).steps[0]
        for type in BlobFinder.Args.ArgType.allCases {
            let row = try XCTUnwrap(listed.args.first { $0.name == "\(type)" })
            XCTAssertEqual(row.value, args.value(for: type) ?? 0, "\(type)")
            XCTAssertEqual(row.isInteger, args.isInteger(type), "\(type)")
            XCTAssertEqual(row.description_p, args.description(for: type), "\(type)")
        }
    }

    func testTheStepsWithNothingToConfigureCarryTheirWords() throws {
        let response = steps(.strong)
        for step in response.steps {
            XCTAssertFalse(step.title.isEmpty, "\(step.kind) has a title")
            XCTAssertFalse(step.title.hasPrefix("ui."), "a missing key shows as itself: \(step.title)")
            XCTAssertFalse(step.description_p.hasPrefix("ui."), "\(step.kind): \(step.description_p)")
            XCTAssertFalse(step.description_p.hasPrefix("view_mode."), "\(step.kind): \(step.description_p)")
            XCTAssertFalse(step.description_p.isEmpty, "\(step.kind) says what it does or carries")
        }
        let save = response.steps[try index(of: "save", in: response)]
        XCTAssertTrue(save.args.isEmpty)
        XCTAssertEqual(save.description_p, "initially detected blobs", "the image it saves, by its name")
        let state = response.steps[try index(of: "frameState", in: response)]
        XCTAssertTrue(state.args.isEmpty && !state.canDisable)
    }

    func testOnlyStepsWithParametersCanBeSkippedAndTheFirstCannot() throws {
        for step in steps(.excessive).steps {
            let configurable = !step.args.isEmpty
            XCTAssertEqual(step.canDisable, configurable && step.kind != "findBlobs", step.kind)
            XCTAssertFalse(step.disabled, "nothing is disabled by default")
        }
    }

    func testTheTypeIsDescribedInTheLanguage() {
        XCTAssertTrue(steps(.mild).description_p.contains("Mild"), steps(.mild).description_p)
        for type in DetectionType.allCases {
            XCTAssertFalse(steps(type).description_p.hasPrefix("ui."), "\(type) has a description")
        }
        StarLocalization.shared.languageOverride = "de"
        XCTAssertNotEqual(steps(.mild).description_p, "", "answers in German too")
        XCTAssertNotEqual(steps(.mild).steps[0].title, "Initial Blob Detection", "the title follows the language")
    }

    func testOnlyTheCustomTypeIsEditable() {
        XCTAssertTrue(BlobSteps.response(for: .custom, processor: CustomBlobProcessor()).editable)
        XCTAssertEqual(BlobSteps.response(for: .custom, processor: CustomBlobProcessor()).detectionType, .detectionCustom)
    }

    // MARK: - changing the custom type

    func testCopyingAnotherTypeReplacesTheStepsWithItsOwn() throws {
        let processor = CustomBlobProcessor()
        let response = try BlobSteps.apply(copy(.mild), to: processor)
        XCTAssertEqual(response.steps.count, DetectionType.mild.blobProcessor.steps.count)
        XCTAssertEqual(processor.steps, DetectionType.mild.blobProcessor.steps)
        let again = try BlobSteps.apply(copy(.excessive), to: processor)
        XCTAssertEqual(again.steps.count, DetectionType.excessive.blobProcessor.steps.count)
        XCTAssertEqual(again.detectionType, .detectionCustom)
    }

    func testTheCustomTypeCannotBeCopiedFromItself() throws {
        XCTAssertThrowsError(try BlobSteps.apply(copy(.custom), to: CustomBlobProcessor())) {
            XCTAssertEqual($0 as? BlobSteps.Failure, .copyFromItself)
        }
    }

    func testAnIntegerParameterIsRoundedAndKept() throws {
        let processor = try custom()
        let response = try BlobSteps.apply(setArg(0, "minPixelIntensity", 1234.6), to: processor)
        let row = try XCTUnwrap(response.steps[0].args.first { $0.name == "minPixelIntensity" })
        XCTAssertEqual(row.value, 1235)
        guard case .findBlobs(let args) = processor.steps[0] else { return XCTFail("the step changed kind") }
        XCTAssertEqual(args.value(for: .minPixelIntensity), 1235)
    }

    func testARealParameterIsKeptAsGiven() throws {
        let processor = try custom()
        let response = try BlobSteps.apply(setArg(0, "startMinContrast", 71.25), to: processor)
        XCTAssertEqual(response.steps[0].args.first { $0.name == "startMinContrast" }?.value, 71.25)
    }

    func testAParameterOfAnotherKindOfStepIsSetToo() throws {
        let processor = try custom(copying: .strong)
        let response = steps(.strong)
        let removerIndex = try index(of: "smallBlobRemover", in: response)
        let name = try XCTUnwrap(response.steps[removerIndex].args.first { $0.isInteger }?.name)
        let changed = try BlobSteps.apply(setArg(removerIndex, name, 77), to: processor)
        XCTAssertEqual(changed.steps[removerIndex].args.first { $0.name == name }?.value, 77)
        XCTAssertEqual(changed.steps[0], steps(.strong).steps[0], "the other steps are as they were")
    }

    func testTheChangeIsKeptInTheFileTheCustomProcessorReadsAtStart() throws {
        let processor = try custom()
        _ = try BlobSteps.apply(setArg(0, "minPixelIntensity", 4321), to: processor)
        // a processor made afterwards reads what was saved
        guard case .findBlobs(let args) = CustomBlobProcessor().steps[0] else { return XCTFail("nothing was saved") }
        XCTAssertEqual(args.value(for: .minPixelIntensity), 4321)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".star_custom_processor_steps.json").path))
    }

    func testAParameterThatIsNotThereIsRefusedAndChangesNothing() throws {
        let processor = try custom()
        let before = processor.steps
        XCTAssertThrowsError(try BlobSteps.apply(setArg(0, "noSuchThing", 1), to: processor)) {
            XCTAssertEqual($0 as? BlobSteps.Failure, .noSuchParameter(step: 0, name: "noSuchThing"))
        }
        let saveIndex = try index(of: "save", in: steps(.strong))
        XCTAssertThrowsError(try BlobSteps.apply(setArg(saveIndex, "x", 1), to: processor)) {
            XCTAssertEqual($0 as? BlobSteps.Failure, .noSuchParameter(step: saveIndex, name: "x"))
        }
        XCTAssertEqual(processor.steps, before)
    }

    func testAStepThatIsNotThereIsRefused() throws {
        let processor = try custom()
        XCTAssertThrowsError(try BlobSteps.apply(setArg(999, "minPixelIntensity", 1), to: processor)) {
            XCTAssertEqual($0 as? BlobSteps.Failure, .noSuchStep(999))
        }
        XCTAssertThrowsError(try BlobSteps.apply(setArg(-1, "minPixelIntensity", 1), to: processor))
        XCTAssertThrowsError(try BlobSteps.apply(setDisabled(999, true), to: processor)) {
            XCTAssertEqual($0 as? BlobSteps.Failure, .noSuchStep(999))
        }
    }

    func testAStepCanBeToldToBeSkippedAndNotToBe() throws {
        let processor = try custom(copying: .strong)
        let removerIndex = try index(of: "smallBlobRemover", in: steps(.strong))
        var response = try BlobSteps.apply(setDisabled(removerIndex, true), to: processor)
        XCTAssertTrue(response.steps[removerIndex].disabled)
        XCTAssertTrue(response.steps.enumerated().allSatisfy { $0.offset == removerIndex || !$0.element.disabled }, "only that one")
        XCTAssertTrue(processor.isDisabled(atIndex: removerIndex), "the processor will skip it")

        response = try BlobSteps.apply(setDisabled(removerIndex, false), to: processor)
        XCTAssertFalse(response.steps[removerIndex].disabled)
        XCTAssertFalse(processor.isDisabled(atIndex: removerIndex))
    }

    func testAStepThatCannotBeSkippedIsNeverReportedSkipped() throws {
        let processor = try custom()
        let response = try BlobSteps.apply(setDisabled(0, true), to: processor)
        XCTAssertFalse(response.steps[0].disabled, "the initial detection is not skippable, whatever was asked")
    }

    func testAnEmptyRequestChangesNothingAndAnswersWithTheSteps() throws {
        let processor = try custom(copying: .mild)
        let response = try BlobSteps.apply(Star_V1_SetCustomBlobStepsRequest(), to: processor)
        XCTAssertEqual(response.steps.count, DetectionType.mild.blobProcessor.steps.count)
    }
}
