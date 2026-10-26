import Foundation

public enum DiagnosticError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case malformedResponse(String)
    case adapter(String)
    case negativeResponse(service: UInt8, reason: UInt8)
    case responsePending
    case timeout
    case disconnected
    case busy

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): return "Invalid configuration: \(detail)"
        case .malformedResponse(let detail): return "Invalid diagnostic response: \(detail)"
        case .adapter(let detail): return "Adapter failure: \(detail)"
        case .negativeResponse(let service, let reason):
            return String(format: "ECU rejected service %02X (reason %02X).", service, reason)
        case .responsePending: return "ECU is still processing. Fault-code status is unknown."
        case .timeout: return "Timed out. Fault-code status is unknown."
        case .disconnected: return "Adapter disconnected. Fault-code status is unknown."
        case .busy: return "Another diagnostic operation is in progress."
        }
    }
}

/// Only these two vehicle requests are exposed. Bluetooth is the connection to the
/// adapter; UDS is the diagnostic protocol addressed to the selected engine ECU.
public enum DMERequest: Sendable {
    case vin
    case pendingAndConfirmedFaults

    public var bytes: [UInt8] {
        switch self {
        case .vin: return [0x22, 0xF1, 0x90]
        case .pendingAndConfirmedFaults: return [0x19, 0x02, 0x0C]
        }
    }
}

public struct FaultRecord: Equatable, Codable, Sendable {
    public let code: String
    public let rawStatus: UInt8
    public let supportedStatus: UInt8

    public var statusLabels: [String] {
        let labels = [
            "Test failed", "Failed this operating cycle", "Pending", "Confirmed",
            "Test not completed since clearing", "Test failed since clearing",
            "Test not completed this operating cycle", "Warning indicator requested"
        ]
        return labels.enumerated().compactMap { bit, label in
            supportedStatus & (1 << bit) != 0 ? label : nil
        }
    }
}

public struct FaultRead: Equatable, Codable, Sendable {
    public let statusAvailability: UInt8
    public let requestedStatusMask: UInt8
    public let faults: [FaultRecord]

    /// A successful empty read only evaluates the status bits supported by the ECU.
    public var evaluatedStatusMask: UInt8 { requestedStatusMask & statusAvailability }
    public var unavailableStatusMask: UInt8 { requestedStatusMask & ~statusAvailability }
}

public struct EngineScan: Equatable, Codable, Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let targetLabel: String
    public let vin: String?
    public let vinRejection: String?
    public let faultRead: FaultRead
}

@MainActor public protocol DMETransport: AnyObject {
    func open() async throws
    func request(_ request: DMERequest) async throws -> [UInt8]
    func close()
}

/// The caller creates a fresh transport for every scan. Failures throw; they
/// never return an empty fault list. No UI, persistence, or uploads are included.
@MainActor public final class DMEReader {
    private let makeTransport: () throws -> any DMETransport
    private var scanning = false

    public init(makeTransport: @escaping () throws -> any DMETransport) {
        self.makeTransport = makeTransport
    }

    public func scan(targetLabel: String = "test vehicle") async throws -> EngineScan {
        guard !scanning else { throw DiagnosticError.busy }
        scanning = true
        defer { scanning = false }
        let started = Date()
        try Task.checkCancellation()
        let transport = try makeTransport()
        defer { transport.close() }
        try await transport.open()
        try Task.checkCancellation()
        var vin: String?
        var vinRejection: String?
        do {
            let response = try await transport.request(.vin)
            vin = try UDS.parseVIN(response)
        } catch let error as DiagnosticError {
            // Only a complete ECU rejection leaves the connection trustworthy.
            // A timeout, truncated frame, or invalid VIN stops this scan.
            guard case .negativeResponse(service: 0x22, reason: _) = error else { throw error }
            vinRejection = error.localizedDescription
        }
        try Task.checkCancellation()
        let response = try await transport.request(.pendingAndConfirmedFaults)
        let faults = try UDS.parseFaults(response)
        try Task.checkCancellation()
        return EngineScan(startedAt: started, finishedAt: Date(), targetLabel: targetLabel,
                          vin: vin, vinRejection: vinRejection, faultRead: faults)
    }
}

public enum UDS {
    /// Accept response-pending followed by a final response in the same adapter
    /// transaction. A pending-only reply is inconclusive and is never retried here.
    public static func response(to request: DMERequest, messages: [[UInt8]]) throws -> [UInt8] {
        var final: [UInt8]?
        var pending = false
        for message in messages {
            guard !message.isEmpty else {
                throw DiagnosticError.malformedResponse("Empty UDS message.")
            }
            if message[0] == 0x7F {
                guard message.count == 3, message[1] == request.bytes[0] else {
                    throw DiagnosticError.malformedResponse("Unmatched negative response.")
                }
                guard final == nil else {
                    throw DiagnosticError.malformedResponse("Response after a final result.")
                }
                if message[2] == 0x78 {
                    pending = true
                    continue
                }
                throw DiagnosticError.negativeResponse(service: message[1], reason: message[2])
            }
            let expected: [UInt8]
            switch request {
            case .vin: expected = [0x62, 0xF1, 0x90]
            case .pendingAndConfirmedFaults: expected = [0x59, 0x02]
            }
            guard message.starts(with: expected), final == nil else {
                throw DiagnosticError.malformedResponse("Unexpected or duplicate UDS response.")
            }
            final = message
        }
        if let final { return final }
        if pending { throw DiagnosticError.responsePending }
        throw DiagnosticError.malformedResponse("No matching ECU result.")
    }

    public static func parseVIN(_ bytes: [UInt8]) throws -> String {
        guard bytes.count == 20, bytes.starts(with: [0x62, 0xF1, 0x90]) else {
            throw DiagnosticError.malformedResponse("VIN response length or identifier.")
        }
        let allowed = Set("0123456789ABCDEFGHJKLMNPRSTUVWXYZ".utf8)
        let vinBytes = Array(bytes.dropFirst(3))
        guard vinBytes.allSatisfy({ allowed.contains($0) }) else {
            throw DiagnosticError.malformedResponse("VIN must contain 17 valid ASCII characters.")
        }
        return String(decoding: vinBytes, as: UTF8.self)
    }

    public static func parseFaults(_ bytes: [UInt8]) throws -> FaultRead {
        guard bytes.count >= 3, bytes.starts(with: [0x59, 0x02]),
              (bytes.count - 3) % 4 == 0 else {
            throw DiagnosticError.malformedResponse("Fault response has incomplete records.")
        }
        let available = bytes[2]
        let requested: UInt8 = 0x0C
        guard available & requested != 0 else {
            throw DiagnosticError.malformedResponse("ECU supports neither requested status bit.")
        }
        var records: [FaultRecord] = []
        var seen: Set<String> = []
        for offset in stride(from: 3, to: bytes.count, by: 4) {
            let record = Array(bytes[offset..<(offset + 4)])
            // Do not mistake a reserved all-zero record for a real DTC.
            if record == [0, 0, 0, 0] { continue }
            let code = record.prefix(3).map { String(format: "%02X", $0) }.joined()
            let status = record[3]
            guard code != "000000", status & available & requested != 0,
                  seen.insert(code).inserted else {
                throw DiagnosticError.malformedResponse("Invalid, duplicate, or out-of-scope fault.")
            }
            records.append(FaultRecord(code: code, rawStatus: status,
                                       supportedStatus: status & available))
        }
        return FaultRead(statusAvailability: available, requestedStatusMask: requested, faults: records)
    }
}
