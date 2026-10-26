import Foundation

public struct BLEAdapterProfile: Equatable, Sendable {
    public enum WriteMode: Sendable {
        case withResponse
        case withoutResponse
    }

    public let peripheralID: UUID
    public let serviceUUID: String
    public let writeUUID: String
    public let notifyUUID: String
    public let writeMode: WriteMode

    /// Supply the selected peripheral ID and manufacturer-documented GATT UUIDs.
    /// This describes an ELM ASCII stream, not arbitrary Bluetooth OBD hardware.
    public init(peripheralID: UUID, serviceUUID: String, writeUUID: String,
                notifyUUID: String, writeMode: WriteMode) throws {
        func normalize(_ value: String) throws -> String {
            let hex = Set("0123456789ABCDEF".utf8)
            let upper = value.uppercased()
            let short = [4, 8].contains(upper.count) && upper.utf8.allSatisfy(hex.contains)
            guard short || UUID(uuidString: upper) != nil else {
                throw DiagnosticError.invalidConfiguration("Invalid Bluetooth service/characteristic UUID.")
            }
            return upper
        }
        self.peripheralID = peripheralID
        self.serviceUUID = try normalize(serviceUUID)
        self.writeUUID = try normalize(writeUUID)
        self.notifyUUID = try normalize(notifyUUID)
        self.writeMode = writeMode
    }
}

#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth

/// Foreground, single-session BLE connection. The containing iOS app must provide
/// NSBluetoothAlwaysUsageDescription and obtain/select a peripheral ID first.
/// No name-based guessing, Bluetooth Classic SPP, or background restoration.
@MainActor public final class CoreBluetoothByteStream: NSObject, AdapterByteStream,
    CBCentralManagerDelegate, CBPeripheralDelegate {

    public var onData: (([UInt8]) -> Void)?
    public var onDisconnect: ((Error) -> Void)?

    private let profile: BLEAdapterProfile
    private let connectTimeout: UInt64
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var outgoing: [UInt8]?
    private var connectTimer: Task<Void, Never>?
    private var started = false
    private var ended = false
    private var ready = false
    private var locating = false

    public init(profile: BLEAdapterProfile, connectionTimeout: TimeInterval = 15) throws {
        guard connectionTimeout.isFinite, (1...120).contains(connectionTimeout) else {
            throw DiagnosticError.invalidConfiguration("BLE connection timeout must be 1...120 seconds.")
        }
        self.profile = profile
        self.connectTimeout = UInt64(connectionTimeout * 1_000_000_000)
        super.init()
    }

    public func connect() async throws {
        guard !started, !ended else { throw DiagnosticError.disconnected }
        started = true
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                connectContinuation = continuation
                connectTimer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: self?.connectTimeout ?? 0) }
                    catch { return }
                    self?.terminate(DiagnosticError.timeout)
                }
                // Delegate callbacks and all operations use the main queue.
                central = CBCentralManager(delegate: self, queue: .main)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.terminate(CancellationError()) }
        })
        try Task.checkCancellation()
    }

    public func write(_ bytes: [UInt8]) async throws {
        try Task.checkCancellation()
        guard ready, !ended, let peripheral, let characteristic = writeCharacteristic else {
            throw DiagnosticError.disconnected
        }
        guard writeContinuation == nil else { throw DiagnosticError.busy }
        let type: CBCharacteristicWriteType = profile.writeMode == .withResponse ? .withResponse : .withoutResponse
        guard !bytes.isEmpty, bytes.count <= peripheral.maximumWriteValueLength(for: type) else {
            throw DiagnosticError.invalidConfiguration("Command exceeds the BLE write limit.")
        }
        try await withCheckedThrowingContinuation { continuation in
            writeContinuation = continuation
            outgoing = bytes
            if type == .withResponse {
                peripheral.writeValue(Data(bytes), for: characteristic, type: type)
            } else {
                sendWithoutResponseWhenReady()
            }
        }
    }

    public func disconnect() { terminate(DiagnosticError.disconnected, notify: false) }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central, !ended else { return }
        switch central.state {
        case .poweredOn:
            guard !locating else { return }
            locating = true
            if let saved = central.retrievePeripherals(withIdentifiers: [profile.peripheralID]).first {
                connectPeripheral(saved)
            } else {
                central.scanForPeripherals(withServices: [CBUUID(string: profile.serviceUUID)])
            }
        case .unknown, .resetting: break // Bounded by the connection deadline.
        case .poweredOff: terminate(DiagnosticError.adapter("Bluetooth is powered off."))
        case .unauthorized: terminate(DiagnosticError.adapter("Bluetooth permission was denied."))
        case .unsupported: terminate(DiagnosticError.adapter("BLE is unavailable."))
        @unknown default: terminate(DiagnosticError.adapter("Unknown Bluetooth state."))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, !ended, self.peripheral == nil,
              peripheral.identifier == profile.peripheralID else { return }
        central.stopScan()
        connectPeripheral(peripheral)
    }

    private func connectPeripheral(_ peripheral: CBPeripheral) {
        guard !ended else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central?.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral, !ended else { return }
        peripheral.discoverServices([CBUUID(string: profile.serviceUUID)])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        guard central === self.central, peripheral === self.peripheral, !ended else { return }
        terminate(error ?? DiagnosticError.disconnected)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        guard central === self.central, peripheral === self.peripheral, !ended else { return }
        terminate(error ?? DiagnosticError.disconnected)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral, !ended else { return }
        if let error { terminate(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: profile.serviceUUID) }) else {
            terminate(DiagnosticError.adapter("Configured BLE service was not found."))
            return
        }
        peripheral.discoverCharacteristics([CBUUID(string: profile.writeUUID),
                                             CBUUID(string: profile.notifyUUID)], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard peripheral === self.peripheral, !ended else { return }
        if let error { terminate(error); return }
        let characteristics = service.characteristics ?? []
        guard let write = characteristics.first(where: { $0.uuid == CBUUID(string: profile.writeUUID) }),
              let notify = characteristics.first(where: { $0.uuid == CBUUID(string: profile.notifyUUID) }),
              notify.properties.contains(.notify) || notify.properties.contains(.indicate) else {
            terminate(DiagnosticError.adapter("Configured BLE characteristics are unavailable."))
            return
        }
        let property: CBCharacteristicProperties = profile.writeMode == .withResponse ? .write : .writeWithoutResponse
        guard write.properties.contains(property) else {
            terminate(DiagnosticError.adapter("Configured BLE write mode is unsupported."))
            return
        }
        writeCharacteristic = write
        notifyCharacteristic = notify
        peripheral.setNotifyValue(true, for: notify)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard peripheral === self.peripheral, characteristic === notifyCharacteristic, !ended else { return }
        if let error { terminate(error); return }
        guard characteristic.isNotifying else {
            terminate(DiagnosticError.adapter("BLE notification subscription failed."))
            return
        }
        ready = true
        connectTimer?.cancel()
        connectTimer = nil
        let continuation = connectContinuation
        connectContinuation = nil
        continuation?.resume()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard peripheral === self.peripheral, characteristic === notifyCharacteristic, !ended else { return }
        if let error { terminate(error); return }
        guard let data = characteristic.value else {
            terminate(DiagnosticError.adapter("BLE notification had no value."))
            return
        }
        onData?(Array(data))
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard peripheral === self.peripheral, characteristic === writeCharacteristic, !ended,
              profile.writeMode == .withResponse else { return }
        if let error { terminate(error); return }
        finishWrite()
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, !ended else { return }
        sendWithoutResponseWhenReady()
    }

    private func sendWithoutResponseWhenReady() {
        guard profile.writeMode == .withoutResponse, let peripheral, let characteristic = writeCharacteristic,
              let outgoing, peripheral.canSendWriteWithoutResponse, writeContinuation != nil else { return }
        peripheral.writeValue(Data(outgoing), for: characteristic, type: .withoutResponse)
        finishWrite()
    }

    private func finishWrite() {
        outgoing = nil
        let continuation = writeContinuation
        writeContinuation = nil
        continuation?.resume()
    }

    private func terminate(_ error: Error, notify: Bool = true) {
        guard !ended else { return }
        ended = true
        ready = false
        connectTimer?.cancel()
        connectTimer = nil
        central?.stopScan()
        peripheral?.delegate = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.delegate = nil
        central = nil
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        outgoing = nil
        let connection = connectContinuation
        let write = writeContinuation
        connectContinuation = nil
        writeContinuation = nil
        connection?.resume(throwing: error)
        write?.resume(throwing: error)
        if notify { onDisconnect?(error) }
    }
}
#endif
