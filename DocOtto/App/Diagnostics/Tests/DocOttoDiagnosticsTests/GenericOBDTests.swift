import XCTest
@testable import DocOttoDiagnostics

final class GenericOBDTests: XCTestCase {
    func testStandardDTCEncodingAndMultipleECUs() throws {
        let messages = try XCTUnwrap(GenericOBD.messages(
            "03\r43 01 33 00 00\r43 03 00 01 33\r>", echo: "03"))
        XCTAssertEqual(try GenericOBD.parseDTCs(messages, service: 0x03), ["P0133", "P0300"])
        XCTAssertEqual(try GenericOBD.parseDTCs([[0x47, 0x40, 0x01]], service: 0x07), ["C0001"])
        XCTAssertEqual(try GenericOBD.parseDTCs([[0x4A, 0x80, 0x0A]], service: 0x0A), ["B000A"])
        XCTAssertEqual(try GenericOBD.parseDTCs([[0x43, 0, 0, 0, 0]], service: 0x03), [])
    }

    func testMultiFrameVINAndOptionalNoData() throws {
        let raw = "014\r0:49020130303030\r1:30303030303030\r2:303030303030\r>"
        let frames = try XCTUnwrap(GenericOBD.messages(raw, echo: "0902"))
        XCTAssertEqual(try GenericOBD.parseVIN(frames), "00000000000000000")
        XCTAssertNil(try GenericOBD.messages("0902\rNO DATA\r>", echo: "0902"))
        XCTAssertThrowsError(try GenericOBD.messages("014\r0:49020130303030\r>", echo: "0902"))
        XCTAssertThrowsError(try GenericOBD.messages("430133\rNO DATA", echo: "03"))
    }

    func testInvalidFramesNeverReturnAFalseCleanResult() {
        XCTAssertThrowsError(try GenericOBD.parseDTCs([[0x43, 0x01]], service: 0x03))
        XCTAssertThrowsError(try GenericOBD.parseDTCs([[0x47, 0x01, 0x33]], service: 0x03))
        XCTAssertThrowsError(try GenericOBD.validateProbe([[0x41, 0x00]]))
        XCTAssertThrowsError(try GenericOBD.parseVIN([[0x49, 0x02, 0x01, 0x41]]))
    }

    @MainActor
    func testGenericScanUsesAutomaticProtocolAndReadOnlyModes() async throws {
        let fake = FakeOBDChannel()
        let reader = GenericOBDReader(makeChannel: { fake })
        var stages: [String] = []
        let scan = try await reader.scan(onStage: { stage in
            switch stage {
            case .connecting: stages.append("connecting")
            case .readingVIN: stages.append("vin")
            case .readingFaults: stages.append("codes")
            }
        })
        XCTAssertEqual(stages, ["connecting", "vin", "codes"])
        XCTAssertNil(scan.vin)
        XCTAssertEqual(scan.storedCodes, ["P0133"])
        XCTAssertEqual(scan.pendingCodes, [])
        XCTAssertNil(scan.permanentCodes)
        XCTAssertEqual(fake.commands, ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0", "0100", "0902", "03", "07", "0A"])
        XCTAssertTrue(fake.closed)
    }

    @MainActor
    func testMode03NoDataCannotBeReportedAsNoFaults() async {
        let fake = FakeOBDChannel()
        fake.storedReply = "NO DATA"
        do {
            _ = try await GenericOBDReader(makeChannel: { fake }).scan()
            XCTFail("A missing stored-code response is not a successful empty scan")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unknown"))
            XCTAssertTrue(fake.closed)
        }
    }
}

@MainActor
private final class FakeOBDChannel: AdapterCommandChannel {
    var commands: [String] = []
    var closed = false
    var storedReply = "4301330000"

    func connect() async throws {}

    func command(_ text: String) async throws -> String {
        commands.append(text)
        switch text {
        case "ATZ": return "ELM327 v1.5"
        case "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0": return "OK"
        case "0100": return "SEARCHING...\r4100BE3FA813"
        case "0902": return "NO DATA"
        case "03": return storedReply
        case "07": return "470000"
        case "0A": return "NO DATA"
        default: throw DiagnosticError.invalidConfiguration("Unexpected OBD command \(text)")
        }
    }

    func disconnect() { closed = true }
}
