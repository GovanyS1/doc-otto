import XCTest
@testable import DocOttoDiagnostics

final class ParsingTests: XCTestCase {
    private let vin = Array("WBA00000000000000".utf8)

    func testVIN() throws {
        XCTAssertEqual(try UDS.parseVIN([0x62, 0xF1, 0x90] + vin), "WBA00000000000000")
        XCTAssertThrowsError(try UDS.parseVIN([0x62, 0xF1, 0x90] + vin.dropLast()))
        XCTAssertThrowsError(try UDS.parseVIN([0x62, 0xF1, 0x90] + Array("WBA0000000000000I".utf8)))
    }

    func testFaultAndStatus27() throws {
        let read = try UDS.parseFaults([0x59, 0x02, 0xFF, 0x21, 0xA0, 0x2D, 0x27])
        XCTAssertEqual(read.faults.first?.code, "21A02D")
        XCTAssertEqual(read.faults.first?.rawStatus, 0x27)
        XCTAssertEqual(read.faults.first?.statusLabels,
                       ["Test failed", "Failed this operating cycle", "Pending", "Test failed since clearing"])
        XCTAssertEqual(read.evaluatedStatusMask, 0x0C)
        XCTAssertEqual(read.unavailableStatusMask, 0)
    }

    func testEmptyReadRequiresSupportedMask() throws {
        XCTAssertEqual(try UDS.parseFaults([0x59, 0x02, 0xFF]).faults, [])
        XCTAssertThrowsError(try UDS.parseFaults([0x59, 0x02, 0x03]))
        XCTAssertThrowsError(try UDS.parseFaults([0x59, 0x02]))
    }

    func testPartialStatusSupportIsExplicit() throws {
        let read = try UDS.parseFaults([0x59, 0x02, 0x04, 0x21, 0xA0, 0x2D, 0x27])
        XCTAssertEqual(read.evaluatedStatusMask, 0x04)
        XCTAssertEqual(read.unavailableStatusMask, 0x08)
        XCTAssertEqual(read.faults[0].statusLabels, ["Pending"])
    }

    func testIncompleteAndDuplicateRecordsFail() {
        XCTAssertThrowsError(try UDS.parseFaults([0x59, 0x02, 0xFF, 0x21]))
        XCTAssertThrowsError(try UDS.parseFaults([0x59, 0x02, 0xFF] +
            [0x21, 0xA0, 0x2D, 0x27, 0x21, 0xA0, 0x2D, 0x27]))
        XCTAssertThrowsError(try UDS.parseFaults([0x59, 0x02, 0xFF, 0, 0, 0, 0x04]))
        XCTAssertThrowsError(try UDS.parseFaults([0x59, 0x02, 0xFF, 0x21, 0xA0, 0x2D, 0x01]))
        XCTAssertEqual(try UDS.parseFaults([0x59, 0x02, 0xFF, 0, 0, 0, 0]).faults, [])
    }

    func testNegativeAndPendingResponses() throws {
        XCTAssertThrowsError(try UDS.response(to: .vin, messages: [[0x7F, 0x22, 0x31]])) {
            XCTAssertEqual($0 as? DiagnosticError, .negativeResponse(service: 0x22, reason: 0x31))
        }
        XCTAssertThrowsError(try UDS.response(to: .vin, messages: [[0x7F, 0x22, 0x78]])) {
            XCTAssertEqual($0 as? DiagnosticError, .responsePending)
        }
        let positive: [UInt8] = [0x62, 0xF1, 0x90] + vin
        XCTAssertEqual(try UDS.response(to: .vin,
                         messages: [[0x7F, 0x22, 0x78], positive]), positive)
    }

    func testUnmatchedOrDuplicateResponsesFail() {
        XCTAssertThrowsError(try UDS.response(to: .vin, messages: [[0x59, 0x02, 0xFF]]))
        XCTAssertThrowsError(try UDS.response(to: .vin, messages: [[0x7F, 0x19, 0x31]]))
        XCTAssertThrowsError(try UDS.response(to: .vin, messages: [[0x7F, 0x22]]))
        XCTAssertThrowsError(try UDS.response(to: .vin, messages: []))
        let reply: [UInt8] = [0x59, 0x02, 0xFF]
        XCTAssertThrowsError(try UDS.response(to: .pendingAndConfirmedFaults, messages: [reply, reply]))
    }

    func testSingleCANFrame() throws {
        var parser = ISOTPAssembler()
        XCTAssertEqual(try parser.consume([0x03, 0x59, 0x02, 0xFF, 0, 0, 0, 0]),
                       [0x59, 0x02, 0xFF])
        try parser.finish()
    }

    func testMultiframeVIN() throws {
        var parser = ISOTPAssembler()
        XCTAssertNil(try parser.consume([0x10, 0x14, 0x62, 0xF1, 0x90, 0x57, 0x42, 0x41]))
        XCTAssertNil(try parser.consume([0x21, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30]))
        XCTAssertEqual(try parser.consume([0x22, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30]),
                       [0x62, 0xF1, 0x90] + vin)
        try parser.finish()
    }

    func testConsecutiveFrameSequenceWraps() throws {
        let payload = Array(repeating: UInt8(0x55), count: 120)
        var parser = ISOTPAssembler()
        XCTAssertNil(try parser.consume([0x10, 120] + Array(payload.prefix(6))))
        var sequence: UInt8 = 1
        var result: [UInt8]?
        for offset in stride(from: 6, to: payload.count, by: 7) {
            let part = Array(payload[offset..<min(offset + 7, payload.count)])
            result = try parser.consume([0x20 | sequence] + part)
            sequence = (sequence + 1) & 0x0F
        }
        XCTAssertEqual(result, payload)
        try parser.finish()
    }

    func testTruncatedAndOutOfOrderCANFail() throws {
        var parser = ISOTPAssembler()
        XCTAssertNil(try parser.consume([0x10, 20, 0x62, 0xF1, 0x90, 0x57, 0x42, 0x41]))
        XCTAssertThrowsError(try parser.finish())
        XCTAssertThrowsError(try parser.consume([0x22, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertThrowsError(try parser.consume([0x03, 0x59, 0x02, 0xFF]))
        var single = ISOTPAssembler()
        XCTAssertThrowsError(try single.consume([0x07, 0x59]))
        XCTAssertThrowsError(try single.consume([0x30, 0, 0]))
        XCTAssertThrowsError(try single.consume([0x21, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertThrowsError(try single.consume([]))
    }

    func testCANReplyRejectsWrongECUAndAdapterErrors() {
        for reply in ["NO DATA", "CAN ERROR", "OK", "?", "STOPPED", "BUFFER FULL",
                      "7E9 03 59 02 FF 00 00 00 00", "7E8 03 59 02", "7E8 0Z 59 02 FF", ""] {
            XCTAssertThrowsError(try ELM327Transport.parseCANReply(reply, echo: "", responseID: 0x7E8),
                                 "Reply must fail: \(reply)")
        }
    }

    func testProfileAndCANConfigurationValidation() throws {
        XCTAssertThrowsError(try CANConfiguration(requestID: 0x7DF, responseID: 0x7E8, bitRate: .kbps500))
        XCTAssertThrowsError(try CANConfiguration(requestID: 0x800, responseID: 0x7E8, bitRate: .kbps500))
        XCTAssertThrowsError(try CANConfiguration(requestID: 0x7E0, responseID: 0x7E0, bitRate: .kbps500))
        XCTAssertThrowsError(try BLEAdapterProfile(peripheralID: UUID(), serviceUUID: "invalid",
                                                  writeUUID: "FFF1", notifyUUID: "FFF2", writeMode: .withResponse))
        let profile = try BLEAdapterProfile(peripheralID: UUID(), serviceUUID: "fff0",
                                            writeUUID: "fff1", notifyUUID: "fff2", writeMode: .withResponse)
        XCTAssertEqual(profile.serviceUUID, "FFF0")
    }
}
