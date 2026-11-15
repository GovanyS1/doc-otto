import Foundation

/// A fresh, serialized HSFZ session for the two allowlisted engine reads.
/// Gateway ACKs never count as an ECU result. Timeout, cancellation, malformed
/// traffic, and disconnect invalidate the session rather than returning no faults.
@MainActor public final class ENETTransport: DMETransport {
    private final class Pending {
        let id: UUID
        let request: DMERequest
        let continuation: CheckedContinuation<[UInt8], Error>
        var result: Result<[UInt8], Error>?
        var writeCompleted = false
        init(id: UUID, request: DMERequest, continuation: CheckedContinuation<[UInt8], Error>) {
            self.id = id
            self.request = request
            self.continuation = continuation
        }
    }

    private let configuration: ENETConfiguration
    private let stream: any AdapterByteStream
    private let onEvent: ((WireEvent) -> Void)?
    private var decoder = HSFZDecoder()
    private var started = false
    private var connected = false
    private var closed = false
    private var pending: Pending?
    private var timer: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    public private(set) var trace: [WireEvent] = []

    public init(stream: any AdapterByteStream, configuration: ENETConfiguration,
                onEvent: ((WireEvent) -> Void)? = nil) {
        self.stream = stream
        self.configuration = configuration
        self.onEvent = onEvent
    }

    #if canImport(Network)
    public convenience init(configuration: ENETConfiguration, onEvent: ((WireEvent) -> Void)? = nil) {
        self.init(stream: NetworkTCPByteStream(configuration: configuration),
                  configuration: configuration, onEvent: onEvent)
    }
    #endif

    public func open() async throws {
        guard !started, !closed else { throw DiagnosticError.disconnected }
        started = true
        stream.onData = { [weak self] bytes in self?.receive(bytes) }
        stream.onDisconnect = { [weak self] error in self?.invalidate(error) }
        record("state", "Connecting to \(configuration.host):\(configuration.port).")
        do {
            try Task.checkCancellation()
            try await stream.connect()
            try Task.checkCancellation()
            guard !closed else { throw DiagnosticError.disconnected }
            connected = true
            record("state", "Gateway connected. ECU responses still need verification.")
        } catch {
            invalidate(error)
            throw error
        }
    }

    public func request(_ request: DMERequest) async throws -> [UInt8] {
        guard connected, !closed else { throw DiagnosticError.disconnected }
        guard pending == nil else { throw DiagnosticError.busy }
        guard decoder.buffer.isEmpty else {
            let error = DiagnosticError.malformedResponse("Incomplete unsolicited HSFZ frame.")
            invalidate(error)
            throw error
        }
        let id = UUID()
        let result = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let work = Pending(id: id, request: request, continuation: continuation)
                pending = work
                let frame = HSFZFrame.request(request, configuration: configuration)
                record("state", request == .vin ? "Reading VIN." : "Reading pending and confirmed engine codes.")
                record("tx", hex(frame.bytes))
                let nanoseconds = UInt64(configuration.timeout * 1_000_000_000)
                timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: nanoseconds) }
                    catch { return }
                    guard let self, self.pending?.id == id else { return }
                    self.invalidate(DiagnosticError.timeout)
                }
                writer = Task { @MainActor [weak self] in
                    guard let self, self.pending?.id == id else { return }
                    do {
                        try await self.stream.write(frame.bytes)
                        guard self.pending?.id == id else { return }
                        self.pending?.writeCompleted = true
                        self.completeIfReady()
                    } catch {
                        guard self.pending?.id == id else { return }
                        self.invalidate(error)
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.pending?.id == id else { return }
                self.invalidate(CancellationError())
            }
        })
        try Task.checkCancellation()
        return result
    }

    public func close() { invalidate(DiagnosticError.disconnected) }

    private func receive(_ bytes: [UInt8]) {
        guard !closed, !bytes.isEmpty else { return }
        do {
            let frames = try decoder.append(bytes)
            for frame in frames {
                record("rx", hex(frame.bytes))
                if frame.control >= 0x40 {
                    throw DiagnosticError.adapter(String(format: "Gateway returned HSFZ error 0x%04X.", frame.control))
                }
                guard frame.control == 1 else { continue }
                guard frame.body.count >= 3 else {
                    throw DiagnosticError.malformedResponse("HSFZ diagnostic frame lacks addresses or payload.")
                }
                guard frame.body[0] == configuration.engineAddress,
                      frame.body[1] == configuration.testerAddress else { continue }
                guard let work = pending else {
                    throw DiagnosticError.malformedResponse("Unsolicited engine response.")
                }
                guard work.result == nil else {
                    throw DiagnosticError.malformedResponse("Duplicate engine response.")
                }
                let payload = Array(frame.body.dropFirst(2))
                // Unlike the ASCII transport, complete TCP frames arrive separately.
                // Reuse the same UDS matcher, preserving pending and negative replies.
                if payload[0] == 0x7F {
                    guard payload.count == 3 else {
                        throw DiagnosticError.malformedResponse("Malformed negative UDS response.")
                    }
                    guard payload[1] == work.request.bytes[0] else { continue }
                } else {
                    let expected: [UInt8] = work.request == .vin ? [0x62, 0xF1, 0x90] : [0x59, 0x02]
                    guard payload.starts(with: expected) else { continue }
                }
                do {
                    work.result = .success(try UDS.response(to: work.request, messages: [payload]))
                } catch DiagnosticError.responsePending {
                    record("state", "ECU is processing the read; the original deadline still applies.")
                } catch let error as DiagnosticError {
                    if case .negativeResponse = error {
                        // A complete rejection leaves framing synchronized. DMEReader
                        // may proceed to the fault read after a rejected VIN request.
                        work.result = .failure(error)
                    } else { throw error }
                }
            }
            // Process the complete receive batch before resolving to catch duplicate
            // or malformed frames coalesced with an apparently valid response.
            completeIfReady()
        } catch { invalidate(error) }
    }

    private func completeIfReady() {
        guard let work = pending, work.writeCompleted, let result = work.result,
              decoder.buffer.isEmpty else { return }
        pending = nil
        timer?.cancel()
        timer = nil
        writer = nil
        work.continuation.resume(with: result)
    }

    private func invalidate(_ error: Error) {
        guard !closed else { return }
        closed = true
        connected = false
        let work = pending
        pending = nil
        timer?.cancel()
        timer = nil
        writer?.cancel()
        writer = nil
        stream.onData = nil
        stream.onDisconnect = nil
        stream.disconnect()
        decoder = HSFZDecoder()
        if work != nil { record("error", error.localizedDescription) }
        record("state", "Connection closed.")
        work?.continuation.resume(throwing: error)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        let sample = bytes.prefix(512).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > 512 ? sample + " … [\(bytes.count) bytes; trace truncated]" : sample
    }

    private func record(_ direction: String, _ text: String) {
        let event = WireEvent(time: Date(), direction: direction, text: text)
        if trace.count == 128 { trace.removeFirst() }
        trace.append(event)
        onEvent?(event)
    }
}
