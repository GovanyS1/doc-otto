import XCTest
@testable import DocOttoDiagnostics

@MainActor private final class FakeENETStream: AdapterByteStream {
    var onData: (([UInt8]) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var onWrite: (([UInt8]) throws -> Void)?
    var writes: [[UInt8]] = []
    var connected = false
    var holdWrite = false
    var openingDelay: UInt64 = 0
    private var waiter: CheckedContinuation<Void, Error>?

    func connect() async throws {
        connected = true
        if openingDelay != 0 { try await Task.sleep(nanoseconds: openingDelay) }
    }
    func write(_ bytes: [UInt8]) async throws {
        writes.append(bytes)
        try onWrite?(bytes)
        if holdWrite { try await withCheckedThrowingContinuation { waiter = $0 } }
    }
    func finishWrite() {
        let continuation = waiter
        waiter = nil
        continuation?.resume()
    }
    func disconnect() {
        connected = false
        let continuation = waiter
        waiter = nil
        continuation?.resume(throwing: DiagnosticError.disconnected)
    }
    func emit(_ bytes: [UInt8]) { onData?(bytes) }
}

@MainActor final class ENETTests: XCTestCase {
    private let vin = [UInt8]([0x62, 0xF1, 0x90]) + Array("WBA00000000000000".utf8)
    private let faults: [UInt8] = [0x59, 0x02, 0xFF, 0x21, 0xA0, 0x2D, 0x27]
    private func frame(_ bytes: [UInt8], source: UInt8 = 0x12, destination: UInt8 = 0xF4) -> [UInt8] {
        HSFZFrame(control: 1, body: [source, destination] + bytes).bytes
    }
    private func transport(_ stream: FakeENETStream, timeout: TimeInterval = 0.15) throws -> ENETTransport {
        ENETTransport(stream: stream, configuration: try ENETConfiguration(host: "192.168.4.1", timeout: timeout))
    }
    private func waitForWrite(_ stream: FakeENETStream) async throws {
        for _ in 0..<200 {
            if !stream.writes.isEmpty { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Request never started")
    }

    func testConfigurationAcceptsOnlyExplicitLocalUnicastEndpoints() throws {
        for host in ["10.0.0.1", "172.16.2.1", "172.31.2.1", "192.168.4.1", "169.254.22.17"] {
            XCTAssertEqual(try ENETConfiguration(host: host).host, host)
        }
        XCTAssertEqual(try ENETConfiguration(host: " 192.168.4.1\n").host, "192.168.4.1")
        for host in ["", "adapter.local", "https://192.168.4.1", "192.168.4.1:6801", "8.8.8.8",
                     "0.0.0.0", "255.255.255.255", "224.0.0.1", "192.168.4.255", "192.168.4.0",
                     "172.32.1.1", "192.168.4.256", "192.168.04.1", "192.168.4.-1", "192.168.4.1\r04",
                     "192.168.1", "192.168.1.1.1", "::1"] {
            XCTAssertThrowsError(try ENETConfiguration(host: host), host)
        }
        XCTAssertThrowsError(try ENETConfiguration(host: "192.168.4.1", port: 0))
        for timeout in [0.0, -1, .infinity, .nan, 31] {
            XCTAssertThrowsError(try ENETConfiguration(host: "192.168.4.1", timeout: timeout))
        }
    }

    func testExactReadOnlyRequestBytesAndIncrementalDecoder() throws {
        let config = try ENETConfiguration(host: "192.168.4.1")
        XCTAssertEqual(HSFZFrame.request(.vin, configuration: config).bytes,
                       [0, 0, 0, 5, 0, 1, 0xF4, 0x12, 0x22, 0xF1, 0x90])
        XCTAssertEqual(HSFZFrame.request(.pendingAndConfirmedFaults, configuration: config).bytes,
                       [0, 0, 0, 5, 0, 1, 0xF4, 0x12, 0x19, 2, 0x0C])
        var decoder = HSFZDecoder()
        var decoded: [HSFZFrame] = []
        let original = HSFZFrame(control: 1, body: [0x12, 0xF4] + vin)
        for byte in original.bytes { decoded += try decoder.append([byte]) }
        XCTAssertEqual(decoded, [original])
        XCTAssertTrue(decoder.buffer.isEmpty)
    }

    func testFullScanWithFragmentationAcknowledgementsAndPendingReplies() async throws {
        let stream = FakeENETStream()
        stream.onWrite = { [self] bytes in
            let ack = HSFZFrame(control: 2, body: Array(bytes.dropFirst(6))).bytes
            if Array(bytes.suffix(3)) == DMERequest.vin.bytes {
                for byte in ack + frame(vin) { stream.emit([byte]) }
            } else {
                stream.emit(ack + frame([0x7F, 0x19, 0x78]) + frame(faults))
            }
        }
        let enet = try transport(stream)
        let scan = try await DMEReader { enet }.scan()
        XCTAssertEqual(scan.vin, "WBA00000000000000")
        XCTAssertEqual(scan.faultRead.faults.first?.code, "21A02D")
        XCTAssertEqual(scan.faultRead.faults.first?.statusLabels, ["Test failed", "Failed this operating cycle", "Pending", "Test failed since clearing"])
        XCTAssertEqual(stream.writes.map { Array($0.suffix(3)) }, [[0x22, 0xF1, 0x90], [0x19, 2, 0x0C]])
        XCTAssertFalse(stream.connected)
    }

    func testGatewayAcknowledgementAloneTimesOutAndInvalidatesConnection() async throws {
        let stream = FakeENETStream()
        stream.onWrite = { bytes in stream.emit(HSFZFrame(control: 2, body: Array(bytes.dropFirst(6))).bytes) }
        let enet = try transport(stream, timeout: 0.05)
        try await enet.open()
        do { _ = try await enet.request(.pendingAndConfirmedFaults); XCTFail("ACK is not an ECU result") }
        catch { XCTAssertEqual(error as? DiagnosticError, .timeout) }
        do { _ = try await enet.request(.pendingAndConfirmedFaults); XCTFail("Closed session reused") }
        catch { XCTAssertEqual(error as? DiagnosticError, .disconnected) }
        XCTAssertFalse(stream.connected)
    }

    func testWrongAddressesAndOtherServicesCannotCompleteRequest() async throws {
        let stream = FakeENETStream()
        stream.onWrite = { [self] _ in
            stream.emit(frame(faults, source: 0x13) + frame(faults, destination: 0xF5) + frame(vin))
        }
        let enet = try transport(stream, timeout: 0.05)
        try await enet.open()
        do { _ = try await enet.request(.pendingAndConfirmedFaults); XCTFail("Unmatched reply accepted") }
        catch { XCTAssertEqual(error as? DiagnosticError, .timeout) }
    }

    func testVINRejectionKeepsSessionSynchronizedForCodeRead() async throws {
        let stream = FakeENETStream()
        stream.onWrite = { [self] bytes in
            stream.emit(frame(Array(bytes.suffix(3)) == DMERequest.vin.bytes ? [0x7F, 0x22, 0x31] : [0x59, 2, 0xFF]))
        }
        let enet = try transport(stream)
        let scan = try await DMEReader { enet }.scan()
        XCTAssertNil(scan.vin)
        XCTAssertNotNil(scan.vinRejection)
        XCTAssertEqual(scan.faultRead.faults, [])
        XCTAssertEqual(stream.writes.count, 2)
    }

    func testMalformedAndOversizedFramesInvalidateInsteadOfReportingEmpty() async throws {
        let invalidReplies: [[UInt8]] = [
            [0, 0x10, 0, 1, 0, 1], // Body above one MiB, rejected from header alone.
            HSFZFrame(control: 1, body: [0x12, 0xF4]).bytes,
            frame([0x7F, 0x19]),
            frame([0x59, 2, 0xFF]) + frame([0x59, 2, 0xFF]),
            frame([0x59, 2, 0xFF]) + [0, 0, 0],
            HSFZFrame(control: 0x40, body: []).bytes
        ]
        for reply in invalidReplies {
            let stream = FakeENETStream()
            stream.onWrite = { _ in stream.emit(reply) }
            let enet = try transport(stream)
            try await enet.open()
            do { _ = try await enet.request(.pendingAndConfirmedFaults); XCTFail("Invalid reply accepted") }
            catch { XCTAssertTrue(error is DiagnosticError) }
            XCTAssertFalse(stream.connected)
        }
    }

    func testTruncatedFrameTimesOut() async throws {
        let stream = FakeENETStream()
        stream.onWrite = { [self] _ in stream.emit(Array(frame(faults).dropLast())) }
        let enet = try transport(stream, timeout: 0.05)
        try await enet.open()
        do { _ = try await enet.request(.pendingAndConfirmedFaults); XCTFail("Truncated response accepted") }
        catch { XCTAssertEqual(error as? DiagnosticError, .timeout) }
    }

    func testPendingRepliesDoNotExtendDeadlineAndTraceIsBounded() async throws {
        let stream = FakeENETStream()
        stream.onWrite = { [self] _ in
            for _ in 0..<150 { stream.emit(frame([0x7F, 0x19, 0x78])) }
        }
        let enet = try transport(stream, timeout: 0.05)
        try await enet.open()
        let clock = ContinuousClock()
        let started = clock.now
        do { _ = try await enet.request(.pendingAndConfirmedFaults); XCTFail("Pending is not a result") }
        catch { XCTAssertEqual(error as? DiagnosticError, .timeout) }
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
        XCTAssertLessThanOrEqual(enet.trace.count, 128)
    }

    func testResultBeforeWriteCompletionWaitsForSend() async throws {
        let stream = FakeENETStream()
        stream.holdWrite = true
        stream.onWrite = { [self] _ in stream.emit(frame(faults)) }
        let enet = try transport(stream)
        try await enet.open()
        var finished = false
        let task = Task { let reply = try await enet.request(.pendingAndConfirmedFaults); finished = true; return reply }
        try await waitForWrite(stream)
        XCTAssertFalse(finished)
        stream.finishWrite()
        let reply = try await task.value
        XCTAssertEqual(reply, faults)
        enet.close()
    }

    func testCancellationDuringWriteReleasesBothWaiters() async throws {
        let stream = FakeENETStream()
        stream.holdWrite = true
        let enet = try transport(stream)
        try await enet.open()
        let task = Task { try await enet.request(.vin) }
        try await waitForWrite(stream)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation did not stop request") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(stream.connected)
    }

    func testConcurrentRequestIsRejectedAndDisconnectUnblocksFirst() async throws {
        let stream = FakeENETStream()
        let enet = try transport(stream)
        try await enet.open()
        let task = Task { try await enet.request(.vin) }
        try await waitForWrite(stream)
        do { _ = try await enet.request(.pendingAndConfirmedFaults); XCTFail("Overlapping request accepted") }
        catch { XCTAssertEqual(error as? DiagnosticError, .busy) }
        stream.onDisconnect?(DiagnosticError.disconnected)
        do { _ = try await task.value; XCTFail("Disconnect did not stop request") }
        catch { XCTAssertEqual(error as? DiagnosticError, .disconnected) }
        XCTAssertFalse(stream.connected)
    }

    func testCancellationDuringOpenClosesStream() async throws {
        let stream = FakeENETStream()
        stream.openingDelay = 10_000_000_000
        let enet = try transport(stream)
        let task = Task { try await enet.open() }
        for _ in 0..<100 {
            if stream.connected { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation did not stop connection") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(stream.connected)
    }
}

#if canImport(Network) && (os(macOS) || targetEnvironment(simulator))
@preconcurrency import Network

/// Local TCP gateway fixture. No network beyond loopback is contacted.
@MainActor private final class LoopbackENETGateway {
    private var listener: NWListener?
    private var peer: NWConnection?
    private var decoder = HSFZDecoder()
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var startTimer: Task<Void, Never>?
    private(set) var requests: [[UInt8]] = []

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        return try await withCheckedThrowingContinuation { continuation in
            startWaiter = continuation
            startTimer = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                self?.finishStart(.failure(DiagnosticError.timeout))
            }
            server.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = state, let port = self.listener?.port {
                        self.finishStart(.success(port.rawValue))
                    } else if case .failed(let error) = state { self.finishStart(.failure(error)) }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.peer = connection
                    connection.start(queue: .main)
                    self.receive()
                }
            }
            server.start(queue: .main)
        }
    }

    private func finishStart(_ result: Result<UInt16, Error>) {
        let waiter = startWaiter
        startWaiter = nil
        startTimer?.cancel()
        startTimer = nil
        waiter?.resume(with: result)
    }

    private func receive() {
        peer?.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    do {
                        for frame in try self.decoder.append(Array(data)) {
                            self.requests.append(frame.body)
                            let reply: [UInt8]
                            if frame.body == [0xF4, 0x12, 0x22, 0xF1, 0x90] {
                                reply = [0x62, 0xF1, 0x90] + Array("WBA00000000000000".utf8)
                            } else if frame.body == [0xF4, 0x12, 0x19, 0x02, 0x0C] {
                                reply = [0x59, 0x02, 0xFF, 0x21, 0xA0, 0x2D, 0x27]
                            } else { self.peer?.cancel(); return }
                            let ack = HSFZFrame(control: 2, body: frame.body).bytes
                            let response = HSFZFrame(control: 1, body: [0x12, 0xF4] + reply).bytes
                            self.peer?.send(content: Data(ack + response), completion: .contentProcessed { _ in })
                        }
                    } catch { self.peer?.cancel(); return }
                }
                if !complete && error == nil { self.receive() }
            }
        }
    }

    func stop() {
        listener?.cancel()
        peer?.cancel()
        startTimer?.cancel()
        listener = nil
        peer = nil
        finishStart(.failure(DiagnosticError.disconnected))
    }
}

@MainActor final class ENETNetworkTests: XCTestCase {
    func testRealNetworkFrameworkLoopbackVINAndFaultScan() async throws {
        let gateway = LoopbackENETGateway()
        let port = try await gateway.start()
        defer { gateway.stop() }
        let configuration = try ENETConfiguration(host: "127.0.0.1", port: port, timeout: 3)
        let transport = ENETTransport(configuration: configuration)
        let scan = try await DMEReader { transport }.scan()
        XCTAssertEqual(scan.vin, "WBA00000000000000")
        XCTAssertEqual(scan.faultRead.faults.first?.code, "21A02D")
        XCTAssertEqual(gateway.requests, [[0xF4, 0x12, 0x22, 0xF1, 0x90], [0xF4, 0x12, 0x19, 0x02, 0x0C]])
        XCTAssertTrue(transport.trace.contains { $0.direction == "rx" })
    }
}
#endif
