import Foundation

/// SAE J1979 emissions diagnostics. These services are not manufacturer-enhanced
/// module diagnostics; the adapter must expose an ELM327-style ASCII interface.
public enum OBDCodeStatus: String, Codable, Sendable, CaseIterable {
    case stored = "Stored"
    case pending = "Pending"
    case permanent = "Permanent"
}

public struct OBDCode: Codable, Equatable, Sendable, Identifiable {
    public let code: String
    public let status: OBDCodeStatus

    public var id: String { "\(status.rawValue):\(code)" }
}

public struct GenericOBDScan: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let targetLabel: String
    public let vin: String?
    /// Optional services are nil when not supported or when no reliable reply arrived.
    /// An empty list, unlike nil, is a completed reply with no codes.
    public let storedCodes: [String]
    public let pendingCodes: [String]?
    public let permanentCodes: [String]?

    public var codes: [OBDCode] {
        storedCodes.map { OBDCode(code: $0, status: .stored) }
        + (pendingCodes ?? []).map { OBDCode(code: $0, status: .pending) }
        + (permanentCodes ?? []).map { OBDCode(code: $0, status: .permanent) }
    }
}

/// ELM327 prompt replies have varying whitespace; CAN multi-frame responses can
/// be displayed as numbered chunks with a length line (e.g. 014, 0:..., 1:...).
/// Do not turn malformed or missing data into an empty fault list.
public enum GenericOBD {
    public static func messages(_ reply: String, echo: String) throws -> [[UInt8]]? {
        var messages: [[UInt8]] = []
        var assembling: [UInt8]? = nil
        var expectedLength: Int? = nil
        var nextChunk = 0
        var sawNoData = false

        func hexBytes(_ text: String) throws -> [UInt8] {
            let compact = text.filter { !$0.isWhitespace }.uppercased()
            guard !compact.isEmpty, compact.count % 2 == 0,
                  compact.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else {
                throw DiagnosticError.malformedResponse("Unexpected ELM327 reply: \(text)")
            }
            let chars = Array(compact)
            return stride(from: 0, to: chars.count, by: 2).compactMap {
                UInt8(String(chars[$0...($0 + 1)]), radix: 16)
            }
        }

        for raw in reply.replacingOccurrences(of: ">", with: "").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if line.isEmpty || line.replacingOccurrences(of: " ", with: "") == echo.uppercased() { continue }
            if line == "SEARCHING..." || line.hasPrefix("BUS INIT:") { continue }
            if line == "NO DATA" { sawNoData = true; continue }
            if ["?", "STOPPED", "UNABLE TO CONNECT", "BUS ERROR", "CAN ERROR", "BUFFER FULL", "ERROR"].contains(line) {
                throw DiagnosticError.adapter(line)
            }
            let compact = line.filter { !$0.isWhitespace }
            // Some ELM versions announce the multi-frame byte length in hex.
            if assembling == nil && (compact.count == 3 || compact.count == 4),
               compact.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
               let length = Int(compact, radix: 16), length > 0, length <= 4096 {
                expectedLength = length
                continue
            }
            if compact.count >= 3, compact[compact.index(after: compact.startIndex)] == ":",
               let index = Int(String(compact.first!), radix: 16) {
                guard index == nextChunk else {
                    throw DiagnosticError.malformedResponse("Missing or out-of-order ELM multi-frame chunk.")
                }
                let bytes = try hexBytes(String(compact.dropFirst(2)))
                if assembling == nil { assembling = [] }
                assembling! += bytes
                nextChunk += 1
                if let length = expectedLength, assembling!.count >= length {
                    let remainder = assembling!.dropFirst(length)
                    guard remainder.allSatisfy({ $0 == 0 }) else {
                        throw DiagnosticError.malformedResponse("Unexpected bytes after ELM multi-frame reply.")
                    }
                    messages.append(Array(assembling!.prefix(length)))
                    assembling = nil
                    expectedLength = nil
                    nextChunk = 0
                }
                continue
            }
            guard assembling == nil, expectedLength == nil else {
                throw DiagnosticError.malformedResponse("Incomplete ELM multi-frame reply.")
            }
            messages.append(try hexBytes(line))
        }
        guard assembling == nil, expectedLength == nil else {
            throw DiagnosticError.malformedResponse("Truncated ELM multi-frame reply.")
        }
        if sawNoData {
            guard messages.isEmpty else {
                throw DiagnosticError.malformedResponse("Conflicting ELM no-data and positive responses.")
            }
            return nil
        }
        guard !messages.isEmpty else {
            throw DiagnosticError.malformedResponse("Adapter did not provide a diagnostic reply.")
        }
        return messages
    }

    public static func validateProbe(_ messages: [[UInt8]]) throws {
        guard messages.contains(where: { $0.count == 6 && $0.starts(with: [0x41, 0x00]) }) else {
            throw DiagnosticError.malformedResponse("No valid OBD-II Mode 01 response. Check adapter protocol and ignition.")
        }
    }

    public static func parseDTCs(_ messages: [[UInt8]], service: UInt8) throws -> [String] {
        guard [0x03, 0x07, 0x0A].contains(service) else {
            throw DiagnosticError.invalidConfiguration("Unsupported DTC request.")
        }
        var codes: [String] = []
        var seen: Set<String> = []
        for message in messages {
            if message.count == 3 && message.starts(with: [0x7F, service]) {
                throw DiagnosticError.negativeResponse(service: service, reason: message[2])
            }
            guard message.first == service + 0x40, (message.count - 1) % 2 == 0 else {
                throw DiagnosticError.malformedResponse("Unexpected or incomplete OBD-II DTC response.")
            }
            for index in stride(from: 1, to: message.count, by: 2) {
                let high = message[index], low = message[index + 1]
                if high == 0 && low == 0 { continue } // Empty DTC slots.
                let system = ["P", "C", "B", "U"][Int(high >> 6)]
                let code = String(format: "%@%01X%01X%02X", system, (high >> 4) & 0x03, high & 0x0F, low)
                if seen.insert(code).inserted { codes.append(code) }
            }
        }
        return codes.sorted()
    }

    public static func parseVIN(_ messages: [[UInt8]]) throws -> String {
        var bytes: [UInt8] = []
        var expectedFrame: UInt8 = 1
        for message in messages {
            if message.count == 3 && message.starts(with: [0x7F, 0x09]) {
                throw DiagnosticError.negativeResponse(service: 0x09, reason: message[2])
            }
            guard message.count >= 4, message.starts(with: [0x49, 0x02]),
                  message[2] == expectedFrame else {
                throw DiagnosticError.malformedResponse("Unexpected or out-of-order OBD-II VIN reply.")
            }
            bytes += message.dropFirst(3)
            expectedFrame += 1
        }
        // Padding after the 17th character is permitted, but not missing data.
        guard bytes.count >= 17, bytes.dropFirst(17).allSatisfy({ $0 == 0 }) else {
            throw DiagnosticError.malformedResponse("VIN response does not contain 17 characters.")
        }
        let allowed = Set("0123456789ABCDEFGHJKLMNPRSTUVWXYZ".utf8)
        guard bytes.prefix(17).allSatisfy({ allowed.contains($0) }) else {
            throw DiagnosticError.malformedResponse("VIN contains invalid characters.")
        }
        return String(decoding: bytes.prefix(17), as: UTF8.self)
    }
}

/// Read-only generic OBD-II scanning via a prompt-based ELM327-compatible adapter.
/// No ECU coding, clearing, reset, or manufacturer-specific requests are issued.
@MainActor public final class GenericOBDReader {
    public enum Stage { case connecting, readingVIN, readingFaults }
    private let makeChannel: () throws -> any AdapterCommandChannel
    private var scanning = false

    public init(makeChannel: @escaping () throws -> any AdapterCommandChannel) {
        self.makeChannel = makeChannel
    }

    public func scan(targetLabel: String = "OBD-II vehicle", onStage: (Stage) -> Void = { _ in }) async throws -> GenericOBDScan {
        guard !scanning else { throw DiagnosticError.busy }
        scanning = true
        defer { scanning = false }
        let start = Date()
        let channel = try makeChannel()
        defer { channel.disconnect() }
        onStage(.connecting)
        try Task.checkCancellation()
        try await channel.connect()
        let banner = try await channel.command("ATZ")
        guard !banner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !banner.contains("?") else {
            throw DiagnosticError.adapter("The adapter did not answer the ELM327 reset command.")
        }
        for setup in ["ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"] {
            try Task.checkCancellation()
            let answer = try await channel.command(setup)
            guard answer.uppercased().components(separatedBy: .newlines)
                .map({ $0.trimmingCharacters(in: .whitespaces) }).contains("OK") else {
                throw DiagnosticError.adapter("ELM327 setup \(setup) failed: \(answer)")
            }
        }
        let probe = try await channel.command("0100")
        guard let available = try GenericOBD.messages(probe, echo: "0100") else {
            throw DiagnosticError.malformedResponse("OBD-II vehicle did not respond to Mode 01.")
        }
        try GenericOBD.validateProbe(available)

        onStage(.readingVIN)
        let vin: String?
        do {
            let vinReply = try await channel.command("0902")
            if let reply = try GenericOBD.messages(vinReply, echo: "0902") {
                vin = try GenericOBD.parseVIN(reply)
            } else {
                vin = nil
            }
        } catch let error as DiagnosticError {
            // A complete unsupported-service rejection is an optional VIN miss.
            if case .negativeResponse(service: 0x09, reason: _) = error { vin = nil }
            else { throw error }
        }

        onStage(.readingFaults)
        func fetch(_ service: UInt8, required: Bool) async throws -> [String]? {
            let command = String(format: "%02X", service)
            let raw = try await channel.command(command)
            guard let messages = try GenericOBD.messages(raw, echo: command) else {
                if required { throw DiagnosticError.malformedResponse("Mode 03 gave NO DATA; stored DTC status is unknown.") }
                return nil
            }
            do { return try GenericOBD.parseDTCs(messages, service: service) }
            catch let error as DiagnosticError {
                if !required, case .negativeResponse = error { return nil }
                throw error
            }
        }
        guard let stored = try await fetch(0x03, required: true) else {
            throw DiagnosticError.malformedResponse("Missing stored-code reply.")
        }
        let pending = try await fetch(0x07, required: false)
        let permanent = try await fetch(0x0A, required: false)
        try Task.checkCancellation()
        return GenericOBDScan(startedAt: start, finishedAt: Date(), targetLabel: targetLabel,
                              vin: vin, storedCodes: stored, pendingCodes: pending, permanentCodes: permanent)
    }
}
