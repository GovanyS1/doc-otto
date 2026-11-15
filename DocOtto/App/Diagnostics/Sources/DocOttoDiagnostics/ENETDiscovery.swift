import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The IP address is taken from the source of a validated BMW HSFZ discovery reply,
/// never guessed from the Wi-Fi router or from a fixed address list.
public struct ENETGateway: Equatable, Sendable {
    public let host: String
    public let vin: String?

    public init(host: String, vin: String? = nil) {
        self.host = host
        self.vin = vin
    }
}

/// Discovers BMW ENET/HSFZ gateways using the same UDP 6811 exchange as the
/// Windows prototype. iOS hardware requires Apple's multicast entitlement for
/// UDP broadcast; simulator/macOS tests do not establish physical compatibility.
public struct ENETDiscovery: Sendable {
    public static let port: UInt16 = 6811
    public static let probe: [UInt8] = [0, 0, 0, 0, 0, 0x11]

    public init() {}

    public func discover(timeout: TimeInterval = 2.5) async throws -> [ENETGateway] {
        guard timeout.isFinite, (0.1...10).contains(timeout) else {
            throw DiagnosticError.invalidConfiguration("Discovery timeout must be between 0.1 and 10 seconds.")
        }
        #if canImport(Darwin)
        // BSD receive is blocking; keep it off the main actor and make cancellation
        // visible through short socket timeouts. Never scan a range of IP addresses.
        let worker = Task.detached(priority: .userInitiated) {
            try Self.discoverOnWiFi(timeout: timeout)
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
        #else
        throw DiagnosticError.adapter("ENET discovery requires an Apple Wi-Fi device.")
        #endif
    }

    /// Validate a complete identification frame and its responding IPv4 source.
    /// Accept a gateway only when the HSFZ control word and DIAGADR marker match.
    static func parseIdentification(_ packet: [UInt8], from host: String) -> ENETGateway? {
        guard packet.count >= 7, packet.count <= 4102 else { return nil }
        let length = (UInt32(packet[0]) << 24) | (UInt32(packet[1]) << 16)
            | (UInt32(packet[2]) << 8) | UInt32(packet[3])
        guard length > 0, length <= 4096, Int(length) + 6 == packet.count,
              packet[4] == 0, packet[5] == 0x11,
              (try? ENETConfiguration(host: host)) != nil else { return nil }

        let payload = Array(packet.dropFirst(6))
        guard find(Array("DIAGADR".utf8), in: payload) != nil else { return nil }
        var vin: String?
        let prefix = Array("BMWVIN".utf8)
        if let position = find(prefix, in: payload), payload.count >= position + prefix.count + 17 {
            let bytes = Array(payload[(position + prefix.count)..<(position + prefix.count + 17)])
            if bytes.allSatisfy({ (48...57).contains($0) || (65...72).contains($0)
                    || (74...78).contains($0) || (80...80).contains($0)
                    || (82...90).contains($0) }) {
                vin = String(bytes: bytes, encoding: .ascii)
            }
        }
        return ENETGateway(host: host, vin: vin)
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for index in 0...(haystack.count - needle.count) {
            if haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
        }
        return nil
    }

    #if canImport(Darwin)
    private static func wiFiAddress() -> in_addr? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(first) }
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == "en0",
                  let address = current.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET,
                  (current.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        }
        return nil
    }

    private static func discoverOnWiFi(timeout: TimeInterval) throws -> [ENETGateway] {
        try Task<Never, Never>.checkCancellation()
        guard let sourceAddress = wiFiAddress() else {
            throw DiagnosticError.adapter("Connect to the MHD adapter in iPhone Wi-Fi settings before scanning.")
        }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw DiagnosticError.adapter("Could not create the ENET discovery socket.") }
        defer { close(fd) }

        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw DiagnosticError.adapter("Could not enable ENET discovery broadcast.")
        }
        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
                       socklen_t(MemoryLayout.size(ofValue: receiveTimeout)))

        var source = sockaddr_in()
        source.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        source.sin_family = sa_family_t(AF_INET)
        source.sin_port = 0
        source.sin_addr = sourceAddress
        let didBind = withUnsafePointer(to: &source) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0 else { throw DiagnosticError.adapter("Could not bind discovery to Wi-Fi.") }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = ENETDiscovery.port.bigEndian
        _ = "255.255.255.255".withCString { inet_pton(AF_INET, $0, &destination.sin_addr) }
        let sent = probe.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == probe.count else {
            throw DiagnosticError.adapter("ENET broadcast was blocked. On a physical iPhone automatic discovery requires Apple's Multicast Networking entitlement. Use Manual IP until it is enabled.")
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var found: [String: ENETGateway] = [:]
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task<Never, Never>.checkCancellation()
            var buffer = [UInt8](repeating: 0, count: 8192)
            var sender = sockaddr_in()
            var senderSize = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &senderSize)
                    }
                }
            }
            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                throw DiagnosticError.adapter("Could not receive ENET gateway discovery replies.")
            }
            guard received > 0, sender.sin_family == sa_family_t(AF_INET) else { continue }
            var address = sender.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let host = String(cString: text)
            if let gateway = parseIdentification(Array(buffer.prefix(received)), from: host) {
                found[host] = gateway
            }
        }
        return found.values.sorted { $0.host < $1.host }
    }
    #endif
}
