import XCTest
import DocOttoDiagnostics
@testable import DocOtto

@MainActor
final class ScanViewModelTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "DocOttoTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func waitFor(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "Operation did not settle", file: file, line: line)
    }

    private func report(_ model: ScanViewModel) throws -> [String: Any] {
        let data = try Data(contentsOf: model.exportReport())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func useManualBMW(_ model: ScanViewModel) {
        model.wifiProtocol = .bmwENET
        model.autoDiscoverENET = false
    }

    func testStartsWithoutGuessedEndpointOrDemoResults() {
        let model = ScanViewModel(defaults: defaults())
        XCTAssertEqual(model.host, "")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.result)
        XCTAssertFalse(model.isDemo)
        XCTAssertFalse(model.canExport)
    }

    func testRealScanReturnsCodesAndExportsTheEndpointAndMasks() async throws {
        let mock = TestTransport(faults: [0x59, 0x02, 0x08, 0x12, 0x34, 0x56, 0x08])
        let model = ScanViewModel(defaults: defaults(), transportFactory: { _, _ in mock })
        useManualBMW(model)
        model.host = "192.168.4.1"
        model.startScan()
        try await waitFor { !model.isScanning }
        XCTAssertEqual(model.phase, .complete)
        XCTAssertEqual(model.result?.vin, "00000000000000002")
        XCTAssertEqual(model.result?.faultRead.faults.first?.code, "123456")
        XCTAssertTrue(mock.closed)
        let json = try report(model)
        XCTAssertEqual(json["source"] as? String, "vehicle")
        XCTAssertEqual(json["host"] as? String, "192.168.4.1")
        XCTAssertEqual(json["evaluated_status_mask_hex"] as? String, "08")
        XCTAssertEqual(json["unavailable_status_mask_hex"] as? String, "04")
        XCTAssertEqual(json["dtc_status"] as? String, "success")
    }

    func testFailedRescanClearsSuccessAndExportsUnknownNotAnEmptyList() async throws {
        var attempt = 0
        let model = ScanViewModel(defaults: defaults(), transportFactory: { _, _ in
            attempt += 1
            return TestTransport(faults: [0x59, 0x02, 0xFF], failure: attempt == 2 ? .timeout : nil)
        })
        useManualBMW(model)
        model.host = "192.168.4.1"
        model.startScan()
        try await waitFor { !model.isScanning }
        XCTAssertEqual(model.result?.faultRead.faults.count, 0)
        let empty = try report(model)
        XCTAssertEqual((empty["faults"] as? [Any])?.count, 0)
        XCTAssertEqual(empty["dtc_status"] as? String, "success")

        model.startScan()
        XCTAssertNil(model.result, "A previous clean scan must disappear immediately.")
        try await waitFor { !model.isScanning }
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.result)
        let failed = try report(model)
        XCTAssertTrue(failed["faults"] is NSNull)
        XCTAssertEqual(failed["dtc_status"] as? String, "unknown")
        XCTAssertFalse((failed["errors"] as? [String] ?? []).isEmpty)
    }

    func testInvalidEndpointClearsPreviousResultWithoutCreatingTransport() async throws {
        var creations = 0
        let model = ScanViewModel(defaults: defaults(), transportFactory: { _, _ in
            creations += 1
            return TestTransport()
        })
        useManualBMW(model)
        model.host = "192.168.4.1"
        model.startScan()
        try await waitFor { !model.isScanning }
        XCTAssertNotNil(model.result)
        model.host = "https://example.com"
        model.startScan()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.result)
        XCTAssertEqual(creations, 1)
        XCTAssertTrue(try report(model)["faults"] is NSNull)
    }

    func testCancelClosesTransportAndLateEventsCannotResurrectTheScan() async throws {
        let mock = GatedTransport()
        var callback: ((WireEvent) -> Void)?
        let model = ScanViewModel(defaults: defaults(), transportFactory: { _, onEvent in
            callback = onEvent
            return mock
        })
        useManualBMW(model)
        model.host = "192.168.4.1"
        model.startScan()
        try await waitFor { mock.openStarted }
        model.cancel()
        XCTAssertTrue(mock.closed)
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertNil(model.result)
        XCTAssertFalse(model.isScanning)
        let count = model.events.count
        callback?(try wireEvent("late callback"))
        XCTAssertEqual(model.events.count, count)
        mock.release()
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertNil(model.result)
        XCTAssertTrue(try report(model)["faults"] is NSNull)
    }

    func testOldRunCannotOverwriteNewRunAfterCancellation() async throws {
        let old = GatedTransport()
        var attempts = 0
        let model = ScanViewModel(defaults: defaults(), transportFactory: { _, _ in
            attempts += 1
            return attempts == 1 ? old : TestTransport()
        })
        useManualBMW(model)
        model.host = "192.168.4.1"
        model.startScan()
        try await waitFor { old.openStarted }
        model.cancel()
        model.startScan()
        try await waitFor { !model.isScanning }
        XCTAssertEqual(model.phase, .complete)
        let result = model.result
        old.release()
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(model.phase, .complete)
        XCTAssertEqual(model.result, result)
    }

    func testActiveRunFreezesEndpointAndRejectsOverlappingScans() async throws {
        let gated = GatedTransport()
        var configuredHosts: [String] = []
        let model = ScanViewModel(defaults: defaults(), transportFactory: { configuration, _ in
            configuredHosts.append(configuration.host)
            return gated
        })
        useManualBMW(model)
        model.host = "192.168.4.1"
        model.startScan()
        try await waitFor { gated.openStarted }
        model.host = "192.168.4.2"
        model.startScan()
        model.startDemo()
        XCTAssertEqual(configuredHosts, ["192.168.4.1"])
        XCTAssertFalse(model.isDemo)
        gated.release()
        try await waitFor { !model.isScanning }
        XCTAssertEqual(model.phase, .complete)
        XCTAssertEqual(model.endpointHost, "192.168.4.1")
        XCTAssertEqual(try report(model)["host"] as? String, "192.168.4.1")
        XCTAssertEqual(model.host, "192.168.4.2")
    }

    func testDemoNeverCreatesNetworkTransportAndIsExplicitInReport() async throws {
        var creations = 0
        let model = ScanViewModel(defaults: defaults(), demoDelayNanoseconds: 0, transportFactory: { _, _ in
            creations += 1
            return TestTransport()
        })
        model.startDemo()
        XCTAssertTrue(model.isDemo)
        try await waitFor { !model.isScanning }
        XCTAssertEqual(creations, 0)
        XCTAssertEqual(model.phase, .complete)
        XCTAssertEqual(model.genericResult?.codes.map(\.code), ["P0133", "P0420"])
        let json = try report(model)
        XCTAssertEqual(json["source"] as? String, "demo")
        XCTAssertEqual(json["demo"] as? Bool, true)
        XCTAssertTrue(json["host"] is NSNull)
        model.reset()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.result)
        XCTAssertFalse(model.isDemo)
        XCTAssertFalse(model.canExport)
    }

    func testGenericWiFiSendsStandardOBDRequestsAndExportsCodes() async throws {
        let fake = GenericTestChannel()
        let model = ScanViewModel(defaults: defaults(), channelFactory: { _ in fake })
        try model.saveConnection(medium: .wifi, wifiProtocol: .standard,
            host: "192.168.4.1", port: "35000", peripheralID: nil, peripheralName: "",
            blePreset: .ffe0, service: "", write: "", notify: "", withResponse: false)
        model.startScan()
        try await waitFor { !model.isScanning }
        XCTAssertEqual(model.phase, .complete)
        XCTAssertEqual(model.genericResult?.storedCodes, ["P0133"])
        XCTAssertEqual(try report(model)["transport"] as? String, "Generic SAE J1979 / ELM327")
        XCTAssertEqual(try report(model)["port"] as? Int, 35000)
        XCTAssertTrue(fake.commands.contains("03"))
        XCTAssertFalse(fake.commands.contains("22F190"))
        XCTAssertTrue(fake.closed)
    }

    func testMissingBLESelectionCannotStartScan() throws {
        let model = ScanViewModel(defaults: defaults())
        XCTAssertThrowsError(try model.saveConnection(medium: .bluetooth, wifiProtocol: .standard,
            host: "", port: "35000", peripheralID: nil, peripheralName: "",
            blePreset: .ffe0, service: "", write: "", notify: "", withResponse: false))
    }

    func testBackgroundSuspensionCancelsAndKeepsStatusUnknown() async throws {
        let gated = GatedTransport()
        let model = ScanViewModel(defaults: defaults(), transportFactory: { _, _ in gated })
        useManualBMW(model)
        model.host = "192.168.4.1"
        model.startScan()
        try await waitFor { gated.openStarted }
        model.suspend()
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertTrue(gated.closed)
        XCTAssertTrue(model.errorMessage?.contains("background") == true)
        XCTAssertTrue(try report(model)["faults"] is NSNull)
        gated.release()
    }

    func testAutomaticENETDiscoveryScansWithoutTypedGateway() async throws {
        var connections: [String] = []
        let model = ScanViewModel(defaults: defaults(), transportFactory: { configuration, _ in
            connections.append(configuration.host)
            return TestTransport()
        }, gatewayDiscovery: { [ENETGateway(host: "169.254.1.17", vin: "WBA00000000000000")] })
        try model.saveConnection(medium: .wifi, wifiProtocol: .bmwENET,
            host: "", port: "35000", peripheralID: nil, peripheralName: "",
            blePreset: .ffe0, service: "", write: "", notify: "", withResponse: false,
            autoDiscoverENET: true)
        XCTAssertTrue(model.hasConnection)
        XCTAssertTrue(model.connectionSummary.contains("Automatic"))
        model.startScan()
        try await waitFor { !model.isScanning }
        XCTAssertEqual(model.phase, .complete)
        XCTAssertEqual(model.host, "", "Discovered IP must not overwrite the manual fallback preference")
        XCTAssertEqual(connections, ["169.254.1.17"])
        XCTAssertEqual(try report(model)["host"] as? String, "169.254.1.17")
        XCTAssertEqual(try report(model)["port"] as? Int, 6801)
    }

    func testAutomaticDiscoveryFailureNeverPretendsTheCarHasNoCodes() async throws {
        var created = false
        let model = ScanViewModel(defaults: defaults(), transportFactory: { _, _ in
            created = true
            return TestTransport()
        }, gatewayDiscovery: { [] })
        model.wifiProtocol = .bmwENET
        model.startScan()
        try await waitFor { !model.isScanning }
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(created)
        XCTAssertNil(model.result)
        XCTAssertTrue(try report(model)["faults"] is NSNull)
        XCTAssertTrue(model.errorMessage?.contains("Manual IP") == true)
    }

    func testAutomaticDiscoveryRejectsMultipleGateways() async throws {
        var created = false
        let model = ScanViewModel(defaults: defaults(), transportFactory: { _, _ in
            created = true
            return TestTransport()
        }, gatewayDiscovery: { [ENETGateway(host: "169.254.1.1"), ENETGateway(host: "169.254.2.1")] })
        model.wifiProtocol = .bmwENET
        model.startScan()
        try await waitFor { !model.isScanning }
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(created)
        XCTAssertTrue(model.errorMessage?.contains("Multiple") == true)
    }

    func testAutomaticDiscoveryCancellationCannotOpenLateConnection() async throws {
        var created = false
        var completeDiscovery: CheckedContinuation<[ENETGateway], Never>?
        let model = ScanViewModel(defaults: defaults(), transportFactory: { _, _ in
            created = true
            return TestTransport()
        }, gatewayDiscovery: {
            await withCheckedContinuation { completeDiscovery = $0 }
        })
        model.wifiProtocol = .bmwENET
        model.startScan()
        try await waitFor { completeDiscovery != nil }
        model.cancel()
        completeDiscovery?.resume(returning: [ENETGateway(host: "169.254.1.1")])
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertFalse(created)
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertTrue(try report(model)["faults"] is NSNull)
    }

    private func wireEvent(_ message: String) throws -> WireEvent {
        let data = try JSONSerialization.data(withJSONObject: [
            "time": 0, "direction": "info", "text": message
        ])
        return try JSONDecoder().decode(WireEvent.self, from: data)
    }
}
@MainActor
private final class GenericTestChannel: AdapterCommandChannel {
    var commands: [String] = []
    var closed = false
    func connect() async throws {}
    func command(_ command: String) async throws -> String {
        commands.append(command)
        switch command {
        case "ATZ": return "ELM327"
        case "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0": return "OK"
        case "0100": return "4100BE3FA813"
        case "0902": return "NO DATA"
        case "03": return "430133"
        case "07": return "470000"
        case "0A": return "NO DATA"
        default: throw DiagnosticError.adapter("Unexpected command \(command)")
        }
    }
    func disconnect() { closed = true }
}

@MainActor
private class TestTransport: DMETransport {
    let faults: [UInt8]
    let failure: DiagnosticError?
    private(set) var closed = false

    init(faults: [UInt8] = [0x59, 0x02, 0xFF, 0x12, 0x34, 0x56, 0x08],
         failure: DiagnosticError? = nil) {
        self.faults = faults
        self.failure = failure
    }

    func open() async throws {
        if let failure { throw failure }
    }

    func request(_ request: DMERequest) async throws -> [UInt8] {
        switch request {
        case .vin: return [0x62, 0xF1, 0x90] + Array("00000000000000002".utf8)
        case .pendingAndConfirmedFaults: return faults
        }
    }

    func close() { closed = true }
}

/// Deliberately uncooperative transport exercises stale asynchronous completions.
@MainActor
private final class GatedTransport: TestTransport {
    private(set) var openStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    override func open() async throws {
        openStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
