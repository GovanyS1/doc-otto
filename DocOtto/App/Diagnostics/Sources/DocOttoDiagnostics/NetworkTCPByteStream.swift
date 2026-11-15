import Foundation

/// A local, manually configured ELM327 Wi-Fi TCP endpoint. Restricting this to
/// private/link-local unicast addresses avoids silently contacting internet hosts.
public struct TCPAdapterConfiguration: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let timeout: TimeInterval

    public init(host: String, port: UInt16 = 35000, timeout: TimeInterval = 8) throws {
        let validated = try ENETConfiguration(host: host, port: port, timeout: timeout)
        self.host = validated.host
        self.port = validated.port
        self.timeout = validated.timeout
    }
}

#if canImport(Network)
@preconcurrency import Network

/// One foreground TCP connection. The containing iOS app supplies
/// NSLocalNetworkUsageDescription. Only the manually entered endpoint is reached.
@MainActor public final class NetworkTCPByteStream: AdapterByteStream {
    public var onData: (([UInt8]) -> Void)?
    public var onDisconnect: ((Error) -> Void)?

    private let host: String
    private let port: UInt16
    private let timeout: TimeInterval
    private var connection: NWConnection?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var connectTimer: Task<Void, Never>?
    private var started = false
    private var ended = false
    private var ready = false
    private var waitingReason: Error?

    public init(configuration: ENETConfiguration) {
        self.host = configuration.host
        self.port = configuration.port
        self.timeout = configuration.timeout
    }

    public init(configuration: TCPAdapterConfiguration) {
        self.host = configuration.host
        self.port = configuration.port
        self.timeout = configuration.timeout
    }

    public func connect() async throws {
        guard !started, !ended else { throw DiagnosticError.disconnected }
        started = true
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                connectContinuation = continuation
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                let parameters = NWParameters(tls: nil, tcp: tcp)
                #if os(iOS) && !targetEnvironment(simulator)
                // Never send vehicle traffic through a cellular route.
                parameters.requiredInterfaceType = .wifi
                #endif
                let peer = NWConnection(host: NWEndpoint.Host(host),
                                        port: NWEndpoint.Port(rawValue: port)!,
                                        using: parameters)
                connection = peer
                peer.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in self?.handle(state) }
                }
                let nanoseconds = UInt64(timeout * 1_000_000_000)
                connectTimer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: nanoseconds) }
                    catch { return }
                    guard let self else { return }
                    self.terminate(self.waitingReason ?? DiagnosticError.timeout)
                }
                peer.start(queue: .main)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.terminate(CancellationError()) }
        })
        try Task.checkCancellation()
    }

    public func write(_ bytes: [UInt8]) async throws {
        try Task.checkCancellation()
        guard ready, !ended, let connection else { throw DiagnosticError.disconnected }
        guard writeContinuation == nil else { throw DiagnosticError.busy }
        guard !bytes.isEmpty, bytes.count <= 64 else {
            throw DiagnosticError.invalidConfiguration("Adapter write exceeds the command limit.")
        }
        try await withCheckedThrowingContinuation { continuation in
            writeContinuation = continuation
            connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self, !self.ended else { return }
                    if let error {
                        self.terminate(DiagnosticError.adapter("TCP write failed: \(error.localizedDescription)"))
                    } else {
                        let write = self.writeContinuation
                        self.writeContinuation = nil
                        write?.resume()
                    }
                }
            })
        }
    }

    public func disconnect() { terminate(DiagnosticError.disconnected, notify: false) }

    private func handle(_ state: NWConnection.State) {
        guard !ended else { return }
        switch state {
        case .ready:
            guard !ready else { return }
            ready = true
            connectTimer?.cancel()
            connectTimer = nil
            let continuation = connectContinuation
            connectContinuation = nil
            receive()
            continuation?.resume()
        case .waiting(let error):
            // The first attempt can enter waiting while the Local Network prompt
            // is displayed. Keep the original deadline and allow the path to recover.
            if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied {
                waitingReason = DiagnosticError.adapter(
                    "Allow Doc Otto in Settings > Privacy & Security > Local Network, then retry.")
            } else {
                waitingReason = DiagnosticError.adapter(
                    "Join the adapter's Wi-Fi network, check its TCP address and port, then retry. \(error.localizedDescription)")
            }
        case .failed(let error):
            terminate(DiagnosticError.adapter("TCP connection failed: \(error.localizedDescription)"))
        case .cancelled:
            terminate(DiagnosticError.disconnected)
        default: break
        }
    }

    private func receive() {
        guard ready, !ended, let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.ended else { return }
                if let data, !data.isEmpty { self.onData?(Array(data)) }
                guard !self.ended else { return }
                if let error {
                    self.terminate(DiagnosticError.adapter("TCP read failed: \(error.localizedDescription)"))
                } else if complete {
                    self.terminate(DiagnosticError.disconnected)
                } else {
                    self.receive()
                }
            }
        }
    }

    private func terminate(_ error: Error, notify: Bool = true) {
        guard !ended else { return }
        ended = true
        ready = false
        connectTimer?.cancel()
        connectTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let opening = connectContinuation
        let writing = writeContinuation
        connectContinuation = nil
        writeContinuation = nil
        opening?.resume(throwing: error)
        writing?.resume(throwing: error)
        if notify { onDisconnect?(error) }
    }
}
#endif
