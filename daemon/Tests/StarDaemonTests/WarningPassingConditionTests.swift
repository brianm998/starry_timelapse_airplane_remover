import XCTest
import StarCore
import StarDaemonMessages

/// Which warnings a client's banner takes down by itself: the ones about the state of the machine, which stop being true on their own.
final class WarningPassingConditionTests: XCTestCase {

    func testThePassingConditionsAreTheMachineStateOnes() {
        func warning(_ kind: StarWarning.Kind) -> StarWarning { StarWarning(kind: kind, severity: .warning, message: "m", suggestion: nil, time: Date()) }
        for kind in [StarWarning.Kind.memoryPressure, .lowSystemMemory, .footprintOverBudget] {
            XCTAssertTrue(warning(kind).describesAPassingCondition, "\(kind)")
        }
        for kind in [StarWarning.Kind.outputWriteFailed, .lowDiskSpace, .previousRunDied, .memoryGatingDisabled] {
            XCTAssertFalse(warning(kind).describesAPassingCondition, "\(kind)")
        }
    }

    /// The field is a bool the client reads by number: its own test pins the same bytes.
    func testTheWarningCarriesWhetherItPasses() throws {
        var w = Star_V1_Warning()
        w.kind = "memoryPressure"
        w.passingCondition = true
        let data = try w.serializedData()
        XCTAssertTrue(try Star_V1_Warning(serializedBytes: data).passingCondition)
        XCTAssertEqual(Array(data.suffix(2)), [0x38, 0x01], "field 7 (passing_condition) is a varint: tag 0x38, value 1")
        XCTAssertFalse(try Star_V1_Warning(serializedBytes: Star_V1_Warning().serializedData()).passingCondition)
    }
}
