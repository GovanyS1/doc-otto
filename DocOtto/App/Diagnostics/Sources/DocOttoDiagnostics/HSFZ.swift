import Foundation

/// A validated local ENET endpoint, obtained from an explicit manual address or
/// from the source of a verified HSFZ UDP discovery identification response.
/// No DNS lookup, subnet sweep, or guessed gateway address is used.
public struct ENETConfiguration: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let timeout: TimeInterval
    public let testerAddress: UInt8 = 0xF4
    public let engineAddress: UInt8 = 0x12

    public init(host: String, port: UInt16 = 6801, timeout: TimeInterval = 8) throws {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({
            !$0.isEmpty && $0.count <= 3 && $0.utf8.allSatisfy { (48...57).contains($0) }
                && ($0.count == 1 || $0.first != "0")
        }) else {
            throw DiagnosticError.invalidConfiguration("Enter the verified gateway's numeric IPv4 address.")
        }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else {
            throw DiagnosticError.invalidConfiguration("Each IPv4 number must be between 0 and 255.")
        }
        let a = octets[0], b = octets[1]
        let isPrivate = a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
        let isLinkLocal = a == 169 && b == 254
        var isLoopbackAllowed = false
        #if os(macOS) || targetEnvironment(simulator)
        isLoopbackAllowed = a == 127
        #endif
        // Without a subnet mask the prototype deliberately excludes .0 and .255;
        // this also avoids the usual directed-broadcast and network addresses.
        guard (isPrivate || isLinkLocal || isLoopbackAllowed),
              octets[3] != 0, octets[3] != 255 else {
            throw DiagnosticError.invalidConfiguration("Use a private or link-local unicast gateway IPv4 address.")
        }
        guard port != 0 else {
            throw DiagnosticError.invalidConfiguration("TCP port must be between 1 and 65535.")
        }
        guard timeout.isFinite, (0.05...30).contains(timeout) else {
            throw DiagnosticError.invalidConfiguration("Timeout must be between 0.05 and 30 seconds.")
        }
        self.host = value
        self.port = port
        self.timeout = timeout
    }
}

/// BMW HSFZ: a four-byte network-order body length, two-byte control word,
/// and (for diagnostic messages) source, destination, and UDS bytes.
/// Independent of Network.framework so stream framing can also be tested on Linux.
struct HSFZFrame: Equatable {
    let control: UInt16
    let body: [UInt8]

    var bytes: [UInt8] {
        let length = UInt32(body.count)
        return [UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
                UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
                UInt8(control >> 8), UInt8(control & 0xFF)] + body
    }

    static func request(_ request: DMERequest, configuration: ENETConfiguration) -> HSFZFrame {
        HSFZFrame(control: 1, body: [configuration.testerAddress, configuration.engineAddress] + request.bytes)
    }
}

struct HSFZDecoder {
    static let maximumBodyLength = 1_048_576
    private(set) var buffer: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) throws -> [HSFZFrame] {
        guard buffer.count + bytes.count <= Self.maximumBodyLength + 6 + 16_384 else {
            throw DiagnosticError.malformedResponse("HSFZ receive buffer exceeded its limit.")
        }
        buffer += bytes
        var offset = 0
        var frames: [HSFZFrame] = []
        while buffer.count - offset >= 6 {
            let size = (UInt32(buffer[offset]) << 24) | (UInt32(buffer[offset + 1]) << 16)
                | (UInt32(buffer[offset + 2]) << 8) | UInt32(buffer[offset + 3])
            guard size <= Self.maximumBodyLength else {
                throw DiagnosticError.malformedResponse("HSFZ frame length exceeded its limit.")
            }
            let length = Int(size)
            guard buffer.count - offset >= length + 6 else { break }
            let control = (UInt16(buffer[offset + 4]) << 8) | UInt16(buffer[offset + 5])
            frames.append(HSFZFrame(control: control, body: Array(buffer[(offset + 6)..<(offset + 6 + length)])))
            offset += length + 6
        }
        if offset != 0 { buffer.removeFirst(offset) }
        return frames
    }
}
