import Foundation

public struct CANConfiguration: Equatable, Sendable {
    public enum BitRate: Sendable {
        case kbps500
        case kbps250

        var elmProtocol: String { self == .kbps500 ? "6" : "8" }
    }

    public let requestID: UInt16
    public let responseID: UInt16
    public let bitRate: BitRate

    /// There are deliberately no default ECU addresses. ENET address 0x12 does
    /// not identify a Bluetooth/CAN route. Verify the route on the test vehicle.
    public init(requestID: UInt16, responseID: UInt16, bitRate: BitRate) throws {
        guard requestID <= 0x7FF, responseID <= 0x7FF,
              requestID != responseID, requestID != 0x7DF else {
            throw DiagnosticError.invalidConfiguration("Use distinct physical 11-bit CAN IDs.")
        }
        self.requestID = requestID
        self.responseID = responseID
        self.bitRate = bitRate
    }

    var setupCommands: [String] {
        [
            "ATE0", "ATL0", "ATS1", "ATH1", "ATD0",
            "ATSP\(bitRate.elmProtocol)", "ATCEA", "ATCAF0", "ATCFC1",
            "ATSH\(String(format: "%03X", requestID))",
            "ATCRA\(String(format: "%03X", responseID))",
            "ATFCSH\(String(format: "%03X", requestID))",
            "ATFCSD300000", "ATFCSM1", "ATAT0", "ATSTFF"
        ]
    }
}

@MainActor public protocol AdapterCommandChannel: AnyObject {
    func connect() async throws
    func command(_ text: String) async throws -> String
    func disconnect()
}

@MainActor public final class ELM327Transport: DMETransport {
    private let channel: any AdapterCommandChannel
    private let configuration: CANConfiguration
    private var ready = false
    private var opening = false
    private var requesting = false

    public init(channel: any AdapterCommandChannel, configuration: CANConfiguration) {
        self.channel = channel
        self.configuration = configuration
    }

    public func open() async throws {
        guard !ready, !opening else { throw DiagnosticError.busy }
        opening = true
        defer { opening = false }
        do {
            try Task.checkCancellation()
            try await channel.connect()
            // Adapter reset only; this is not UDS ECUReset or code clearing.
            let banner = try await channel.command("ATZ")
            guard banner.uppercased().contains("ELM327") else {
                throw DiagnosticError.adapter("Expected an ELM327-compatible startup banner.")
            }
            for command in configuration.setupCommands {
                try Task.checkCancellation()
                let reply = try await channel.command(command)
                let lines = Self.lines(reply, excludingEcho: command)
                guard lines == ["OK"] else {
                    throw DiagnosticError.adapter("Setup command \(command) was rejected: \(reply)")
                }
            }
            try Task.checkCancellation()
            ready = true
        } catch {
            close()
            throw error
        }
    }

    public func request(_ request: DMERequest) async throws -> [UInt8] {
        guard ready else { throw DiagnosticError.disconnected }
        guard !requesting else { throw DiagnosticError.busy }
        requesting = true
        defer { requesting = false }
        try Task.checkCancellation()
        let bytes = request.bytes
        let frame = [UInt8(bytes.count)] + bytes + Array(repeating: UInt8(0), count: 7 - bytes.count)
        let command = frame.map { String(format: "%02X", $0) }.joined()
        do {
            let reply = try await channel.command(command)
            try Task.checkCancellation()
            let messages = try Self.parseCANReply(reply, echo: command,
                                                 responseID: configuration.responseID)
            return try UDS.response(to: request, messages: messages)
        } catch let error as DiagnosticError {
            // Complete ECU rejection is synchronized. All other errors invalidate
            // this session so late bytes cannot become a later request's reply.
            if case .negativeResponse = error { throw error }
            close()
            throw error
        } catch {
            close()
            throw error
        }
    }

    public func close() {
        ready = false
        channel.disconnect()
    }

    nonisolated private static func lines(_ reply: String, excludingEcho echo: String) -> [String] {
        reply.uppercased().components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.replacingOccurrences(of: " ", with: "") != echo }
    }

    nonisolated static func parseCANReply(_ reply: String, echo: String, responseID: UInt16) throws -> [[UInt8]] {
        var assembler = ISOTPAssembler()
        var messages: [[UInt8]] = []
        for line in lines(reply, excludingEcho: echo) {
            // Headers and DLC formatting are explicitly configured above.
            let compact = line.filter { !$0.isWhitespace }
            guard compact.count >= 5, (compact.count - 3) % 2 == 0,
                  compact.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
                  let identifier = UInt16(compact.prefix(3), radix: 16) else {
                throw DiagnosticError.adapter("Expected a raw CAN frame, received: \(line)")
            }
            guard identifier == responseID else {
                throw DiagnosticError.malformedResponse("Reply came from an unexpected CAN ID.")
            }
            let dataHex = Array(compact.dropFirst(3))
            var data: [UInt8] = []
            for offset in stride(from: 0, to: dataHex.count, by: 2) {
                guard let byte = UInt8(String(dataHex[offset...offset + 1]), radix: 16) else {
                    throw DiagnosticError.malformedResponse("Invalid hexadecimal CAN data.")
                }
                data.append(byte)
            }
            if let message = try assembler.consume(data) { messages.append(message) }
        }
        try assembler.finish()
        guard !messages.isEmpty else {
            throw DiagnosticError.malformedResponse("No complete diagnostic message was returned.")
        }
        return messages
    }
}
