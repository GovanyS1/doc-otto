import XCTest
@testable import DocOttoDiagnostics

@MainActor private final class FakeStream: AdapterByteStream {
    var onData: (([UInt8]) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var writes: [[UInt8]] = []
    var connected = false
    var onWrite: (([UInt8]) throws -> Void)?
    var holdWrite = false
    private var writeWaiter: CheckedContinuation<Void, Error>?

    func connect() async throws { connected = true }
    func write(_ bytes: [UInt8]) async throws {
        writes.append(bytes)
        try onWrite?(bytes)
        if holdWrite {
            try await withCheckedThrowingContinuation { writeWaiter = $0 }
        }
    }
    func acknowledgeWrite() {
        let continuation = writeWaiter
        writeWaiter = nil
        continuation?.resume()
    }
    func disconnect() {
        connected = false
        let continuation = writeWaiter
        writeWaiter = nil
        continuation?.resume(throwing: DiagnosticError.disconnected)
    }
    func emit(_ text: String) { onData?(Array(text.utf8)) }
}

@MainActor private final class FakeCommands: AdapterCommandChannel {
    var commands: [String] = []
    var connected = false
    var replies: [String: String] = [:]
    func connect() async throws { connected = true }
    func command(_ text: String) async throws -> String {
        commands.append(text)
        if let reply = replies[text] { return reply }
        if text == "ATZ" { return "ELM327 v2.3\r" }
        if text.hasPrefix("AT") { return "OK\r" }
        throw DiagnosticError.timeout
    }
    func disconnect() { connected = false }
}

@MainActor private final class FakeDME: DMETransport {
    var closed = false
    var requests: [DMERequest] = []
    var vinFailure: DiagnosticError?
    var faults: [UInt8] = [0x59, 0x02, 0xFF]
    var waitAtOpen = false
    var openStarted = false
    func open() async throws {
        openStarted = true
        if waitAtOpen { try await Task.sleep(nanoseconds: 10_000_000_000) }
    }
    func request(_ request: DMERequest) async throws -> [UInt8] {
        requests.append(request)
        switch request {
        case .vin:
            if let vinFailure { throw vinFailure }
            return [0x62, 0xF1, 0x90] + Array("WBA00000000000000".utf8)
        case .pendingAndConfirmedFaults: return faults
        }
    }
    func close() { closed = true }
}

@MainActor final class SessionTests: XCTestCase {
    private func waitForWrite(_ stream: FakeStream) async throws {
        for _ in 0..<100 {
            if !stream.writes.isEmpty { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Test command never started")
    }

    func testNotificationFragmentsAndPromptBeforeWriteAcknowledgement() async throws {
        let stream = FakeStream()
        stream.holdWrite = true
        stream.onWrite = { _ in stream.emit("O"); stream.emit("K\r>") }
        let channel = try PromptCommandChannel(stream: stream)
        try await channel.connect()
        let task = Task { try await channel.command("ATE0") }
        try await waitForWrite(stream)
        XCTAssertEqual(stream.writes[0], Array("ATE0\r".utf8))
        stream.acknowledgeWrite()
        let reply = try await task.value
        XCTAssertEqual(reply, "OK\r")
        XCTAssertEqual(channel.trace.map(\.direction), ["tx", "rx"])
        channel.disconnect()
    }

    func testTimeoutInvalidatesSessionAndLateReplyCannotBecomeAnEmptyRead() async throws {
        let stream = FakeStream()
        let channel = try PromptCommandChannel(stream: stream, timeout: 0.05)
        try await channel.connect()
        do {
            _ = try await channel.command("ATE0")
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? DiagnosticError, .timeout) }
        stream.emit("OK\r>")
        do {
            _ = try await channel.command("ATE0")
            XCTFail("Must require a fresh connection")
        } catch { XCTAssertEqual(error as? DiagnosticError, .disconnected) }
        XCTAssertFalse(stream.connected)
    }

    func testCancellationDisconnects() async throws {
        let stream = FakeStream()
        let channel = try PromptCommandChannel(stream: stream)
        try await channel.connect()
        let task = Task { try await channel.command("ATI") }
        try await waitForWrite(stream)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(stream.connected)
    }

    func testConcurrentCommandsAreRejected() async throws {
        let stream = FakeStream()
        let channel = try PromptCommandChannel(stream: stream)
        try await channel.connect()
        let task = Task { try await channel.command("ATI") }
        try await waitForWrite(stream)
        do { _ = try await channel.command("ATE0"); XCTFail("Expected busy") }
        catch { XCTAssertEqual(error as? DiagnosticError, .busy) }
        stream.emit("ELM327 v2.3\r>")
        let reply = try await task.value
        XCTAssertEqual(reply, "ELM327 v2.3\r")
        channel.disconnect()
    }

    func testDisconnectDuringCommand() async throws {
        let stream = FakeStream()
        let channel = try PromptCommandChannel(stream: stream)
        try await channel.connect()
        stream.onWrite = { _ in stream.onDisconnect?(DiagnosticError.disconnected) }
        do { _ = try await channel.command("ATI"); XCTFail("Expected disconnect") }
        catch { XCTAssertEqual(error as? DiagnosticError, .disconnected) }
    }

    func testOversizedAndAmbiguousPromptRepliesFail() async throws {
        for reply in [String(repeating: "A", count: 32769), "OK>NO DATA>"] {
            let stream = FakeStream()
            let channel = try PromptCommandChannel(stream: stream)
            try await channel.connect()
            stream.onWrite = { _ in stream.emit(reply) }
            do { _ = try await channel.command("ATI"); XCTFail("Expected malformed reply") }
            catch { XCTAssertTrue(error is DiagnosticError) }
            XCTAssertFalse(stream.connected)
        }
    }

    func testInvalidCommandCannotInjectAnotherRequest() async throws {
        let stream = FakeStream()
        let channel = try PromptCommandChannel(stream: stream)
        try await channel.connect()
        do { _ = try await channel.command("ATI\r04"); XCTFail("Expected validation failure") }
        catch { XCTAssertTrue(error is DiagnosticError) }
        XCTAssertTrue(stream.writes.isEmpty)
        channel.disconnect()
    }

    func testFullReaderThroughELMAndFragmentedBLE() async throws {
        let stream = FakeStream()
        var commands: [String] = []
        stream.onWrite = { bytes in
            let command = String(decoding: bytes.dropLast(), as: UTF8.self)
            commands.append(command)
            let reply: String
            switch command {
            case "ATZ": reply = "ATZ\rELM327 v2.3\r>"
            case "0322F19000000000":
                reply = "7E8 10 14 62 F1 90 57 42 41\r7E8 21 30 30 30 30 30 30 30\r7E8 22 30 30 30 30 30 30 30\r>"
            case "0319020C00000000": reply = "7E8 07 59 02 FF 21 A0 2D 27\r>"
            default: reply = "OK\r>"
            }
            // Exercise arbitrary BLE fragmentation rather than line-sized chunks.
            for byte in reply.utf8 { stream.onData?([byte]) }
        }
        let channel = try PromptCommandChannel(stream: stream)
        let config = try CANConfiguration(requestID: 0x7E0, responseID: 0x7E8, bitRate: .kbps500)
        let reader = DMEReader { ELM327Transport(channel: channel, configuration: config) }
        let result = try await reader.scan()
        XCTAssertEqual(result.vin, "WBA00000000000000")
        XCTAssertEqual(result.faultRead.faults.first?.code, "21A02D")
        XCTAssertFalse(stream.connected)
        XCTAssertEqual(commands.filter { !$0.hasPrefix("AT") },
                       ["0322F19000000000", "0319020C00000000"])
        XCTAssertTrue(commands.contains("ATFCSH7E0"))
        XCTAssertTrue(commands.contains("ATFCSD300000"))
        XCTAssertTrue(commands.contains("ATFCSM1"))
    }

    func testRejectedSetupStopsBeforeVehicleRequests() async throws {
        let channel = FakeCommands()
        channel.replies["ATCAF0"] = "?\r"
        let config = try CANConfiguration(requestID: 0x7E0, responseID: 0x7E8, bitRate: .kbps500)
        let transport = ELM327Transport(channel: channel, configuration: config)
        do { try await transport.open(); XCTFail("Expected unsupported adapter") }
        catch { XCTAssertTrue(error is DiagnosticError) }
        XCTAssertTrue(channel.commands.allSatisfy { $0.hasPrefix("AT") })
        XCTAssertFalse(channel.connected)
    }

    func testEmptySuccessIsDistinctFromNoData() async throws {
        for reply in ["7E8 03 59 02 FF 00 00 00 00\r", "NO DATA\r"] {
            let channel = FakeCommands()
            channel.replies["0319020C00000000"] = reply
            let config = try CANConfiguration(requestID: 0x7E0, responseID: 0x7E8, bitRate: .kbps500)
            let transport = ELM327Transport(channel: channel, configuration: config)
            try await transport.open()
            do {
                let result = try await transport.request(.pendingAndConfirmedFaults)
                XCTAssertEqual(try UDS.parseFaults(result).faults, [])
                XCTAssertTrue(reply.hasPrefix("7E8"))
            } catch { XCTAssertEqual(reply, "NO DATA\r") }
            transport.close()
        }
    }

    func testVINRejectionStillAllowsFaultRead() async throws {
        let transport = FakeDME()
        transport.vinFailure = .negativeResponse(service: 0x22, reason: 0x31)
        let result = try await DMEReader { transport }.scan()
        XCTAssertNil(result.vin)
        XCTAssertNotNil(result.vinRejection)
        XCTAssertEqual(result.faultRead.faults, [])
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(transport.closed)
    }

    func testVINTimeoutStopsBeforeFaultRead() async throws {
        let transport = FakeDME()
        transport.vinFailure = .timeout
        do { _ = try await DMEReader { transport }.scan(); XCTFail("Expected scan failure") }
        catch { XCTAssertEqual(error as? DiagnosticError, .timeout) }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(transport.closed)
    }

    func testReaderBusyAndCancellationCleanUp() async throws {
        let transport = FakeDME()
        transport.waitAtOpen = true
        let reader = DMEReader { transport }
        let first = Task { try await reader.scan() }
        for _ in 0..<100 {
            if transport.openStarted { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(transport.openStarted)
        do { _ = try await reader.scan(); XCTFail("Expected busy") }
        catch { XCTAssertEqual(error as? DiagnosticError, .busy) }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(transport.closed)
    }

    func testTransportFactoryFailureDoesNotLeaveReaderBusy() async throws {
        var fail = true
        let transport = FakeDME()
        let reader = DMEReader {
            if fail { throw DiagnosticError.invalidConfiguration("Missing adapter profile") }
            return transport
        }
        do { _ = try await reader.scan(); XCTFail("Expected configuration failure") }
        catch { XCTAssertTrue(error is DiagnosticError) }
        fail = false
        let result = try await reader.scan()
        XCTAssertEqual(result.faultRead.faults, [])
    }

    func testCancelledScanNeverOpensTransport() async throws {
        var created = false
        let reader = DMEReader {
            created = true
            return FakeDME()
        }
        let task = Task {
            try Task.checkCancellation()
            return try await reader.scan()
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(created)
    }

    func testCancellationWhileWriteIsUnacknowledgedReleasesBothWaiters() async throws {
        let stream = FakeStream()
        stream.holdWrite = true
        let channel = try PromptCommandChannel(stream: stream)
        try await channel.connect()
        let task = Task { try await channel.command("ATE0") }
        try await waitForWrite(stream)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(stream.connected)
    }

    func testUnsolicitedIdleReplyInvalidatesChannel() async throws {
        let stream = FakeStream()
        let channel = try PromptCommandChannel(stream: stream)
        try await channel.connect()
        stream.onWrite = { _ in stream.emit("OK\r>") }
        _ = try await channel.command("ATE0")
        stream.emit("7E8 03 59 02 FF\r>")
        do { _ = try await channel.command("ATI"); XCTFail("Expected invalidated connection") }
        catch { XCTAssertEqual(error as? DiagnosticError, .disconnected) }
    }

    func testCompleteVINRejectionKeepsELMSynchronized() async throws {
        let channel = FakeCommands()
        channel.replies["0322F19000000000"] = "7E8 03 7F 22 31 00 00 00 00\r"
        channel.replies["0319020C00000000"] = "7E8 03 59 02 FF 00 00 00 00\r"
        let config = try CANConfiguration(requestID: 0x7E0, responseID: 0x7E8, bitRate: .kbps500)
        let result = try await DMEReader {
            ELM327Transport(channel: channel, configuration: config)
        }.scan()
        XCTAssertNil(result.vin)
        XCTAssertNotNil(result.vinRejection)
        XCTAssertEqual(result.faultRead.faults, [])
        XCTAssertFalse(channel.connected)
    }
}
