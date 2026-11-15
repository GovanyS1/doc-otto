import XCTest
@testable import DocOttoDiagnostics

final class ENETDiscoveryTests: XCTestCase {
    private func identification(body: [UInt8], control: UInt16 = 0x11) -> [UInt8] {
        let count = UInt32(body.count)
        return [UInt8(count >> 24), UInt8((count >> 16) & 0xFF),
                UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF),
                UInt8(control >> 8), UInt8(control & 0xFF)] + body
    }

    func testProbeMatchesWindowsENETDiscovery() {
        XCTAssertEqual(ENETDiscovery.probe, [0, 0, 0, 0, 0, 0x11])
        XCTAssertEqual(ENETDiscovery.port, 6811)
    }

    func testValidReplyUsesSenderNotAnAssumedGateway() {
        let body = Array("DIAGADR10BMWMACAABBCCDDEEFFBMWVINWBA00000000000000".utf8)
        XCTAssertEqual(ENETDiscovery.parseIdentification(identification(body: body), from: "169.254.23.61"),
                       ENETGateway(host: "169.254.23.61", vin: "WBA00000000000000"))
        XCTAssertEqual(ENETDiscovery.parseIdentification(identification(body: Array("DIAGADR10".utf8)), from: "192.168.4.1"),
                       ENETGateway(host: "192.168.4.1"))
    }

    func testRejectsUnrelatedMalformedAndNonLocalReplies() {
        let good = identification(body: Array("DIAGADR10BMWVINWBA00000000000000".utf8))
        XCTAssertNil(ENETDiscovery.parseIdentification(Array(good.dropLast()), from: "169.254.1.1"))
        XCTAssertNil(ENETDiscovery.parseIdentification(identification(body: [1, 2, 3]), from: "169.254.1.1"))
        XCTAssertNil(ENETDiscovery.parseIdentification(identification(body: Array("DIAGADR10".utf8), control: 1), from: "169.254.1.1"))
        XCTAssertNil(ENETDiscovery.parseIdentification(good, from: "8.8.8.8"))
        XCTAssertNil(ENETDiscovery.parseIdentification(good, from: "255.255.255.255"))
        XCTAssertNil(ENETDiscovery.parseIdentification([0, 0, 0, 0, 0, 0x11], from: "169.254.1.1"))
        XCTAssertNil(ENETDiscovery.parseIdentification([0, 0, 0x10, 1, 0, 0x11] + [UInt8](repeating: 0, count: 4097), from: "169.254.1.1"))
    }

    func testInvalidVINDoesNotInvalidateAnOtherwiseValidGateway() {
        let body = Array("DIAGADR10BMWVININVALID0000000000".utf8)
        let result = ENETDiscovery.parseIdentification(identification(body: body), from: "169.254.1.2")
        XCTAssertEqual(result, ENETGateway(host: "169.254.1.2", vin: nil))
    }
}
