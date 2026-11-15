import Foundation
import Combine
import DocOttoDiagnostics

struct ScanLogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let direction: String
    let message: String
    let hex: String?
}

enum ConnectionMedium: String, CaseIterable, Identifiable {
    case wifi = "Wi-Fi"
    case bluetooth = "Bluetooth BLE"
    var id: String { rawValue }
}

enum WiFiScannerProtocol: String, CaseIterable, Identifiable {
    case standard = "Universal OBD-II (ELM327)"
    case bmwENET = "BMW MHD ENET (legacy)"
    var id: String { rawValue }
}

enum BLEUARTPreset: String, CaseIterable, Identifiable {
    case ffe0 = "FFE0 / FFE1 UART"
    case nordic = "Nordic UART"
    case custom = "Custom GATT UUIDs"
    var id: String { rawValue }

    func profile(id: UUID, service: String, write: String, notify: String,
                 withResponse: Bool) throws -> BLEAdapterProfile {
        switch self {
        case .ffe0:
            return try BLEAdapterProfile(peripheralID: id, serviceUUID: "FFE0", writeUUID: "FFE1",
                                         notifyUUID: "FFE1", writeMode: .withoutResponse)
        case .nordic:
            return try BLEAdapterProfile(peripheralID: id,
                                         serviceUUID: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
                                         writeUUID: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E",
                                         notifyUUID: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E",
                                         writeMode: .withoutResponse)
        case .custom:
            return try BLEAdapterProfile(peripheralID: id, serviceUUID: service,
                                         writeUUID: write, notifyUUID: notify,
                                         writeMode: withResponse ? .withResponse : .withoutResponse)
        }
    }
}
/// Foreground UI state. Every run owns a fresh transport and an immutable endpoint.
@MainActor
final class ScanViewModel: ObservableObject {
    enum Phase: String {
        case idle, connecting, readingVIN, readingFaults, complete, failed, cancelled

        var isActive: Bool {
            self == .connecting || self == .readingVIN || self == .readingFaults
        }
    }

    typealias TransportFactory = @MainActor (
        ENETConfiguration, @escaping (WireEvent) -> Void
    ) throws -> any DMETransport
    typealias GatewayDiscovery = @MainActor () async throws -> [ENETGateway]
    enum GenericConnection {
        case wifi(TCPAdapterConfiguration)
        case ble(BLEAdapterProfile)
    }
    typealias ChannelFactory = @MainActor (GenericConnection) throws -> any AdapterCommandChannel

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: EngineScan?
    @Published private(set) var genericResult: GenericOBDScan?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isDemo = false
    @Published private(set) var events: [ScanLogEntry] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var endpointHost: String?
    @Published private(set) var endpointPort: UInt16?
    @Published private(set) var selectedConnection: String?
    @Published private(set) var scannedProtocol: String?

    @Published var host: String {
        didSet { defaults.set(host, forKey: Self.hostKey) }
    }
    @Published var portString: String { didSet { defaults.set(portString, forKey: "docotto.wifi.port") } }
    @Published var medium: ConnectionMedium {
        didSet { defaults.set(medium.rawValue, forKey: "docotto.medium") }
    }
    @Published var wifiProtocol: WiFiScannerProtocol {
        didSet { defaults.set(wifiProtocol.rawValue, forKey: "docotto.wifi.protocol") }
    }
    @Published var autoDiscoverENET: Bool {
        didSet { defaults.set(autoDiscoverENET, forKey: "docotto.enet.autoDiscover") }
    }
    @Published var peripheralID: UUID? {
        didSet { defaults.set(peripheralID?.uuidString, forKey: "docotto.ble.id") }
    }
    @Published var peripheralName: String {
        didSet { defaults.set(peripheralName, forKey: "docotto.ble.name") }
    }
    @Published var blePreset: BLEUARTPreset {
        didSet { defaults.set(blePreset.rawValue, forKey: "docotto.ble.preset") }
    }
    @Published var customService: String { didSet { defaults.set(customService, forKey: "docotto.ble.service") } }
    @Published var customWrite: String { didSet { defaults.set(customWrite, forKey: "docotto.ble.write") } }
    @Published var customNotify: String { didSet { defaults.set(customNotify, forKey: "docotto.ble.notify") } }
    @Published var customWithResponse: Bool { didSet { defaults.set(customWithResponse, forKey: "docotto.ble.withResponse") } }

    var isScanning: Bool { phase.isActive }
    var canExport: Bool { startedAt != nil && !isScanning }
    var hasConnection: Bool {
        if medium == .bluetooth { return peripheralID != nil }
        return wifiProtocol == .bmwENET && autoDiscoverENET || !host.isEmpty
    }
    var hasResult: Bool { result != nil || genericResult != nil }
    var totalCodeCount: Int? { genericResult?.codes.count ?? result?.faultRead.faults.count }
    var scannedVIN: String? { genericResult?.vin ?? result?.vin }
    var connectionSummary: String {
        if medium == .bluetooth { return peripheralName.isEmpty ? "Select a BLE adapter" : peripheralName }
        if wifiProtocol == .bmwENET && autoDiscoverENET {
            return endpointHost.map { "Discovered ENET gateway at \($0):6801" }
                ?? "Automatic ENET gateway discovery"
        }
        if host.isEmpty { return "Set up your adapter connection" }
        return "\(host):\(wifiProtocol == .bmwENET ? "6801" : portString)"
    }

    private static let hostKey = "docotto.enet.host"
    private let defaults: UserDefaults
    private let transportFactory: TransportFactory
    private let gatewayDiscovery: GatewayDiscovery
    private let channelFactory: ChannelFactory
    private let demoDelayNanoseconds: UInt64
    private var activeRun: UUID?
    private var scanTask: Task<Void, Never>?
    private var activeTransport: (any DMETransport)?
    private var activeChannel: (any AdapterCommandChannel)?

    init(
        defaults: UserDefaults = .standard,
        demoDelayNanoseconds: UInt64 = 350_000_000,
        transportFactory: @escaping TransportFactory = { configuration, onEvent in
            ENETTransport(configuration: configuration, onEvent: onEvent)
        },
        gatewayDiscovery: @escaping GatewayDiscovery = { try await ENETDiscovery().discover() },
        channelFactory: @escaping ChannelFactory = { connection in
            let stream: any AdapterByteStream
            switch connection {
            case .wifi(let configuration):
                stream = NetworkTCPByteStream(configuration: configuration)
            case .ble(let profile):
                stream = try CoreBluetoothByteStream(profile: profile)
            }
            return try PromptCommandChannel(stream: stream, timeout: 12)
        }
    ) {
        self.defaults = defaults
        self.transportFactory = transportFactory
        self.gatewayDiscovery = gatewayDiscovery
        self.channelFactory = channelFactory
        self.demoDelayNanoseconds = demoDelayNanoseconds
        self.host = defaults.string(forKey: Self.hostKey) ?? ""
        self.portString = defaults.string(forKey: "docotto.wifi.port") ?? "35000"
        self.medium = ConnectionMedium(rawValue: defaults.string(forKey: "docotto.medium") ?? "") ?? .wifi
        self.wifiProtocol = WiFiScannerProtocol(rawValue: defaults.string(forKey: "docotto.wifi.protocol") ?? "") ?? .standard
        self.autoDiscoverENET = defaults.object(forKey: "docotto.enet.autoDiscover") as? Bool ?? true
        self.peripheralID = defaults.string(forKey: "docotto.ble.id").flatMap(UUID.init(uuidString:))
        self.peripheralName = defaults.string(forKey: "docotto.ble.name") ?? ""
        self.blePreset = BLEUARTPreset(rawValue: defaults.string(forKey: "docotto.ble.preset") ?? "") ?? .ffe0
        self.customService = defaults.string(forKey: "docotto.ble.service") ?? ""
        self.customWrite = defaults.string(forKey: "docotto.ble.write") ?? ""
        self.customNotify = defaults.string(forKey: "docotto.ble.notify") ?? ""
        self.customWithResponse = defaults.bool(forKey: "docotto.ble.withResponse")
    }

    /// Validate the whole choice before replacing preferences or clearing results.
    func saveConnection(medium: ConnectionMedium, wifiProtocol: WiFiScannerProtocol,
                        host: String, port: String, peripheralID: UUID?, peripheralName: String,
                        blePreset: BLEUARTPreset, service: String, write: String,
                        notify: String, withResponse: Bool, autoDiscoverENET: Bool = false) throws {
        guard !isScanning else { throw DiagnosticError.busy }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if medium == .wifi {
            if wifiProtocol == .bmwENET {
                if !autoDiscoverENET { _ = try ENETConfiguration(host: host) }
            }
            else {
                guard let number = UInt16(port), number > 0 else {
                    throw DiagnosticError.invalidConfiguration("Enter a TCP port from 1 to 65535.")
                }
                _ = try TCPAdapterConfiguration(host: host, port: number)
            }
        } else {
            guard let peripheralID else {
                throw DiagnosticError.invalidConfiguration("Select a nearby BLE scanner first.")
            }
            _ = try blePreset.profile(id: peripheralID, service: service, write: write,
                                      notify: notify, withResponse: withResponse)
        }
        reset()
        self.medium = medium
        self.wifiProtocol = wifiProtocol
        self.autoDiscoverENET = autoDiscoverENET
        self.host = host
        self.portString = port
        self.peripheralID = peripheralID
        self.peripheralName = peripheralName
        self.blePreset = blePreset
        self.customService = service
        self.customWrite = write
        self.customNotify = notify
        self.customWithResponse = withResponse
    }

    func startScan() {
        guard !isScanning else { return }
        let run = begin(demo: false)
        do {
            switch medium {
            case .wifi:
                let enteredHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
                endpointHost = enteredHost
                selectedConnection = ConnectionMedium.wifi.rawValue
                if wifiProtocol == .bmwENET {
                    scannedProtocol = "BMW ENET / HSFZ (raw UDS)"
                    endpointPort = 6801
                    if autoDiscoverENET {
                        endpointHost = nil
                        discoverAndScanENET(run: run)
                    } else {
                        let configuration = try ENETConfiguration(host: enteredHost, port: 6801, timeout: 8)
                        let transport = try makeENETTransport(configuration: configuration, run: run)
                        execute(transport: transport, run: run, target: "BMW engine ECU")
                    }
                } else {
                    guard let port = UInt16(portString), port > 0 else {
                        throw DiagnosticError.invalidConfiguration("Enter an ELM327 TCP port from 1 to 65535.")
                    }
                    let config = try TCPAdapterConfiguration(host: enteredHost, port: port)
                    endpointPort = config.port
                    scannedProtocol = "Generic SAE J1979 / ELM327"
                    try executeGeneric(connection: .wifi(config), run: run)
                }
            case .bluetooth:
                guard let peripheralID else {
                    throw DiagnosticError.invalidConfiguration("Select a Bluetooth LE adapter in Connection.")
                }
                let profile = try blePreset.profile(id: peripheralID, service: customService,
                                                    write: customWrite, notify: customNotify,
                                                    withResponse: customWithResponse)
                selectedConnection = "Bluetooth LE: \(peripheralName.isEmpty ? peripheralID.uuidString : peripheralName)"
                scannedProtocol = "Generic SAE J1979 / ELM327 over BLE UART"
                try executeGeneric(connection: .ble(profile), run: run)
            }
        } catch {
            fail(error, run: run)
        }
    }

    func startDemo() {
        guard !isScanning else { return }
        let run = begin(demo: true)
        append("Demo uses synthetic data. No adapter connection is made.")
        scannedProtocol = "Generic OBD-II simulated replies"
        selectedConnection = "Demo"
        executeGeneric(channel: DemoOBDChannel(delayNanoseconds: demoDelayNanoseconds),
                       run: run, target: "Demo vehicle (synthetic data)")
    }

    func cancel() {
        stop(message: "Scan cancelled. Fault-code status is unknown.")
    }

    /// Call only when the scene enters the background, not when it becomes
    /// inactive for the Local Network system permission prompt.
    func suspend() {
        stop(message: "Scan stopped when the app entered the background. Run a new scan.")
    }

    func reset() {
        if isScanning { cancel() }
        activeRun = nil
        result = nil
        genericResult = nil
        errorMessage = nil
        isDemo = false
        events = []
        startedAt = nil
        finishedAt = nil
        endpointHost = nil
        endpointPort = nil
        selectedConnection = nil
        scannedProtocol = nil
        phase = .idle
    }

    /// Explicit user action only. Failed/cancelled reads encode faults as null.
    func exportReport() throws -> URL {
        guard canExport, let startedAt else {
            throw DiagnosticError.invalidConfiguration("Finish or cancel the scan before sharing its report.")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var report: [String: Any] = [
            "app": "Doc Otto iOS prototype",
            "version": "0.1.0",
            "source": isDemo ? "demo" : "vehicle",
            "demo": isDemo,
            "target": isDemo ? "Demo vehicle (synthetic data)" :
                (genericResult?.targetLabel ?? result?.targetLabel ?? "OBD-II vehicle, emissions ECU only"),
            "transport": scannedProtocol ?? "Not connected",
            "adapter_connection": selectedConnection ?? "Not connected",
            "phase": phase.rawValue,
            "dtc_status": hasResult ? "success" : "unknown",
            "hardware_validation": "Generic Wi-Fi/BLE and BMW ENET physical vehicle compatibility not yet validated",
            "started_utc": formatter.string(from: startedAt),
            "host": endpointHost as Any? ?? NSNull(),
            "port": endpointPort as Any? ?? NSNull(),
            "ble_peripheral_id": isDemo || selectedConnection?.hasPrefix("Bluetooth") != true ? NSNull() : (peripheralID?.uuidString as Any? ?? NSNull()),
            "finished_utc": finishedAt.map(formatter.string(from:)) as Any? ?? NSNull(),
            "errors": errorMessage.map { [$0] } ?? [],
            "vin": NSNull(),
            "vin_rejection": NSNull(),
            "faults": NSNull(),
            "status_availability_hex": NSNull(),
            "evaluated_status_mask_hex": NSNull(),
            "unavailable_status_mask_hex": NSNull(),
            "trace": events.map { event -> [String: Any] in
                [
                    "time_utc": formatter.string(from: event.time),
                    "direction": event.direction,
                    "message": event.message,
                    "frame_hex": event.hex as Any? ?? NSNull()
                ]
            }
        ]
        if let result {
            report["tester_address_hex"] = "F4"
            report["ecu_address_hex"] = "12"
            report["requested_status_mask_hex"] = "0C"
            report["vin"] = result.vin as Any? ?? NSNull()
            report["vin_rejection"] = result.vinRejection as Any? ?? NSNull()
            report["status_availability_hex"] = hex(result.faultRead.statusAvailability)
            report["evaluated_status_mask_hex"] = hex(result.faultRead.evaluatedStatusMask)
            report["unavailable_status_mask_hex"] = hex(result.faultRead.unavailableStatusMask)
            report["faults"] = result.faultRead.faults.map { fault in
                [
                    "code": fault.code,
                    "status_hex": hex(fault.rawStatus),
                    "supported_status_hex": hex(fault.supportedStatus),
                    "status_flags": fault.statusLabels
                ] as [String: Any]
            }
        } else if let genericResult {
            report["obd_modes"] = ["01 00", "09 02", "03", "07", "0A"]
            report["vin"] = genericResult.vin as Any? ?? NSNull()
            report["stored_codes"] = genericResult.storedCodes
            report["pending_codes"] = genericResult.pendingCodes as Any? ?? NSNull()
            report["permanent_codes"] = genericResult.permanentCodes as Any? ?? NSNull()
            report["faults"] = genericResult.codes.map { ["code": $0.code, "status": $0.status.rawValue] }
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocOttoReports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("DocOtto-Scan.json")
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        return url
    }

    private func begin(demo: Bool) -> UUID {
        let run = UUID()
        activeRun = run
        result = nil
        genericResult = nil
        errorMessage = nil
        isDemo = demo
        events = []
        startedAt = Date()
        finishedAt = nil
        endpointHost = nil
        endpointPort = nil
        selectedConnection = nil
        scannedProtocol = nil
        phase = .connecting
        return run
    }

    private func executeGeneric(connection: GenericConnection, run: UUID) throws {
        let channel = try channelFactory(connection)
        executeGeneric(channel: channel, run: run, target: "OBD-II emissions ECU")
    }

    private func executeGeneric(channel: any AdapterCommandChannel, run: UUID, target: String) {
        activeChannel = channel
        let reader = GenericOBDReader(makeChannel: { channel })
        scanTask = Task { [weak self] in
            do {
                let scan = try await reader.scan(targetLabel: target, onStage: { [weak self] stage in
                    guard let self, self.activeRun == run else { return }
                    switch stage {
                    case .connecting: self.phase = .connecting
                    case .readingVIN: self.phase = .readingVIN
                    case .readingFaults: self.phase = .readingFaults
                    }
                })
                guard let self, self.activeRun == run, !Task.isCancelled else { return }
                self.genericResult = scan
                self.finishedAt = Date()
                self.phase = .complete
                self.append("Standard OBD-II read complete: \(scan.codes.count) code/status record(s).")
                self.end(run: run)
            } catch {
                guard let self, self.activeRun == run else { return }
                self.fail(error, run: run)
            }
        }
    }

    private func execute(transport: any DMETransport, run: UUID, target: String) {
        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.readENET(transport: transport, run: run, target: target)
        }
    }

    private func makeENETTransport(configuration: ENETConfiguration, run: UUID) throws -> any DMETransport {
        try transportFactory(configuration) { [weak self] event in
            guard let self, self.activeRun == run else { return }
            self.append(event)
        }
    }

    private func discoverAndScanENET(run: UUID) {
        append("Searching for a BMW ENET gateway over Wi-Fi (UDP 6811)...")
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let gateways = try await self.gatewayDiscovery()
                try Task.checkCancellation()
                guard self.activeRun == run else { return }
                guard let gateway = gateways.first else {
                    throw DiagnosticError.adapter("No BMW ENET gateway responded. Confirm the MHD Wi-Fi network and ignition. On a physical iPhone discovery requires Apple's Multicast Networking entitlement; use Manual IP until enabled.")
                }
                guard gateways.count == 1 else {
                    throw DiagnosticError.adapter("Multiple BMW ENET gateways responded. Choose Manual IP to select your vehicle safely.")
                }
                let configuration = try ENETConfiguration(host: gateway.host, port: 6801, timeout: 8)
                let transport = try self.makeENETTransport(configuration: configuration, run: run)
                self.endpointHost = configuration.host
                self.append("Found BMW ENET gateway at \(gateway.host). Opening read-only connection.")
                await self.readENET(transport: transport, run: run, target: "BMW engine ECU")
            } catch {
                self.fail(error, run: run)
            }
        }
    }

    private func readENET(transport: any DMETransport, run: UUID, target: String) async {
        activeTransport = transport
        let tracked = ProgressDMETransport(transport: transport) { [weak self] phase in
            guard let self, self.activeRun == run else { return }
            self.phase = phase
        }
        let reader = DMEReader { tracked }
        do {
            let scan = try await reader.scan(targetLabel: target)
            guard activeRun == run, !Task.isCancelled else { return }
            result = scan
            finishedAt = Date()
            phase = .complete
            append("Engine read complete: \(scan.faultRead.faults.count) returned code(s).")
            end(run: run)
        } catch {
            guard activeRun == run else { return }
            fail(error, run: run)
        }
    }

    private func fail(_ error: Error, run: UUID) {
        guard activeRun == run else { return }
        result = nil
        genericResult = nil
        finishedAt = Date()
        errorMessage = error.localizedDescription
        phase = error is CancellationError ? .cancelled : .failed
        append(error.localizedDescription)
        end(run: run)
    }

    private func stop(message: String) {
        guard isScanning else { return }
        // Invalidate callbacks before closing; a delayed completion cannot mutate
        // a later run or resurrect a result after cancellation.
        activeRun = nil
        scanTask?.cancel()
        activeTransport?.close()
        activeChannel?.disconnect()
        activeTransport = nil
        activeChannel = nil
        scanTask = nil
        result = nil
        genericResult = nil
        finishedAt = Date()
        errorMessage = message
        phase = .cancelled
        append(message)
    }

    private func end(run: UUID) {
        guard activeRun == run else { return }
        activeRun = nil
        activeTransport = nil
        activeChannel = nil
        scanTask = nil
    }

    private func append(_ message: String) {
        append(ScanLogEntry(time: Date(), direction: "info", message: message, hex: nil))
    }

    private func append(_ event: WireEvent) {
        let isFrame = event.direction == "tx" || event.direction == "rx"
        append(ScanLogEntry(
            time: event.time,
            direction: event.direction,
            message: isFrame ? (event.direction == "tx" ? "Sent diagnostic frame" : "Received gateway frame") : event.text,
            hex: isFrame ? event.text : nil
        ))
    }

    private func append(_ event: ScanLogEntry) {
        if events.count >= 128 { events.removeFirst(events.count - 127) }
        events.append(event)
    }

    private func hex(_ value: UInt8) -> String { String(format: "%02X", value) }
}

@MainActor
private final class ProgressDMETransport: DMETransport {
    private let transport: any DMETransport
    private let onPhase: (ScanViewModel.Phase) -> Void

    init(transport: any DMETransport, onPhase: @escaping (ScanViewModel.Phase) -> Void) {
        self.transport = transport
        self.onPhase = onPhase
    }

    func open() async throws {
        onPhase(.connecting)
        try await transport.open()
    }

    func request(_ request: DMERequest) async throws -> [UInt8] {
        switch request {
        case .vin: onPhase(.readingVIN)
        case .pendingAndConfirmedFaults: onPhase(.readingFaults)
        }
        return try await transport.request(request)
    }

    func close() { transport.close() }
}

@MainActor
private final class DemoOBDChannel: AdapterCommandChannel {
    private let delayNanoseconds: UInt64
    private var closed = false

    init(delayNanoseconds: UInt64) { self.delayNanoseconds = delayNanoseconds }

    func connect() async throws { try await pause() }

    func command(_ text: String) async throws -> String {
        try await pause()
        switch text {
        case "ATZ": return "ELM327 demo"
        case "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0": return "OK"
        case "0100": return "4100BE3FA813"
        case "0902":
            return ([0x49, 0x02, 0x01] + Array("00000000000000001".utf8))
                .map { String(format: "%02X", $0) }.joined()
        case "03": return "4301330000"  // P0133, stored
        case "07": return "4704200000"  // P0420, pending
        case "0A": return "4A0000"       // No permanent codes in this sample
        default: throw DiagnosticError.invalidConfiguration("Unknown demo request.")
        }
    }

    func disconnect() { closed = true }

    private func pause() async throws {
        try Task.checkCancellation()
        guard !closed else { throw DiagnosticError.disconnected }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        try Task.checkCancellation()
        guard !closed else { throw DiagnosticError.disconnected }
    }
}
