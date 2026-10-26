import Foundation

/// A BLE UART-style byte stream. Notification boundaries are not message boundaries.
@MainActor public protocol AdapterByteStream: AnyObject {
    var onData: (([UInt8]) -> Void)? { get set }
    var onDisconnect: ((Error) -> Void)? { get set }
    func connect() async throws
    func write(_ bytes: [UInt8]) async throws
    func disconnect()
}

public struct WireEvent: Codable, Sendable {
    public let time: Date
    public let direction: String
    public let text: String
}

/// One command at a time, terminated by ELM's '>' prompt. Each instance owns one
/// connection only. Timeout/cancellation/disconnect permanently invalidates it.
@MainActor public final class PromptCommandChannel: AdapterCommandChannel {
    private final class Pending {
        let id = UUID()
        let continuation: CheckedContinuation<String, Error>
        var buffer: [UInt8] = []
        var reply: String?
        var writeCompleted = false

        init(_ continuation: CheckedContinuation<String, Error>) {
            self.continuation = continuation
        }
    }

    private let stream: any AdapterByteStream
    private let timeoutNanoseconds: UInt64
    private var started = false
    private var connected = false
    private var closed = false
    private var sentCommand = false
    private var pending: Pending?
    private var timeoutTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    public private(set) var trace: [WireEvent] = []

    public init(stream: any AdapterByteStream, timeout: TimeInterval = 12) throws {
        guard timeout.isFinite, (0.05...120).contains(timeout) else {
            throw DiagnosticError.invalidConfiguration("Command timeout must be 0.05...120 seconds.")
        }
        self.stream = stream
        self.timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
    }

    public func connect() async throws {
        guard !started, !closed else { throw DiagnosticError.disconnected }
        started = true
        stream.onData = { [weak self] bytes in self?.receive(bytes) }
        stream.onDisconnect = { [weak self] error in self?.invalidate(error) }
        do {
            try Task.checkCancellation()
            try await stream.connect()
            try Task.checkCancellation()
            guard !closed else { throw DiagnosticError.disconnected }
            connected = true
        } catch {
            invalidate(error)
            throw error
        }
    }

    public func command(_ text: String) async throws -> String {
        guard connected, !closed else { throw DiagnosticError.disconnected }
        guard pending == nil else { throw DiagnosticError.busy }
        guard !text.isEmpty, text.utf8.count <= 64,
              text.utf8.allSatisfy({ (32...126).contains($0) && $0 != 62 }) else {
            throw DiagnosticError.invalidConfiguration("Command contains invalid ASCII or terminators.")
        }
        let transaction = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let work = Pending(continuation)
                pending = work
                cancellationToken = transaction
                let id = work.id
                sentCommand = true
                record("tx", text)
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: self?.timeoutNanoseconds ?? 0) }
                    catch { return }
                    guard let self, self.pending?.id == id else { return }
                    self.invalidate(DiagnosticError.timeout)
                }
                writeTask = Task { @MainActor [weak self] in
                    guard let self, self.pending?.id == id else { return }
                    do {
                        try await self.stream.write(Array(text.utf8) + [13])
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
            // Cancellation is scheduled onto the same actor as notification handling.
            // A transaction token prevents cancellation from affecting a later command.
            Task { @MainActor in
                self?.cancel(transaction: transaction)
            }
        })
    }

    // A command cannot overlap another one. Keep its token separately from the
    // continuation so a delayed cancellation cannot close a different transaction.
    private var cancellationToken: UUID?

    private func cancel(transaction: UUID) {
        guard cancellationToken == transaction else { return }
        invalidate(CancellationError())
    }

    public func disconnect() { invalidate(DiagnosticError.disconnected) }

    private func record(_ direction: String, _ text: String) {
        // Bounded in-memory trace only. Saving/sharing is the future caller's choice.
        if trace.count == 64 { trace.removeFirst() }
        trace.append(WireEvent(time: Date(), direction: direction, text: text))
    }

    private func receive(_ bytes: [UInt8]) {
        guard !closed else { return }
        guard let work = pending else {
            // Adapter boot chatter can arrive before the first command. Unsolicited
            // replies after a transaction make the stream unsafe to reuse.
            if sentCommand && bytes.contains(where: { ![9, 10, 13, 32].contains($0) }) {
                invalidate(DiagnosticError.malformedResponse("Unsolicited adapter bytes."))
            }
            return
        }
        guard bytes.allSatisfy({ $0 < 128 }),
              work.buffer.count + bytes.count <= 32768 else {
            invalidate(DiagnosticError.malformedResponse("Non-ASCII or oversized adapter reply."))
            return
        }
        work.buffer += bytes
        guard let end = work.buffer.firstIndex(of: 62) else { return }
        guard work.buffer.dropFirst(end + 1).allSatisfy({ [9, 10, 13, 32].contains($0) }) else {
            invalidate(DiagnosticError.malformedResponse("Unexpected data after the ELM prompt."))
            return
        }
        work.reply = String(decoding: work.buffer[..<end], as: UTF8.self)
        completeIfReady()
    }

    private func completeIfReady() {
        guard let work = pending, work.writeCompleted, let reply = work.reply else { return }
        pending = nil
        cancellationToken = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        writeTask = nil
        record("rx", reply)
        work.continuation.resume(returning: reply)
    }

    private func invalidate(_ error: Error) {
        guard !closed else { return }
        closed = true
        connected = false
        let work = pending
        pending = nil
        cancellationToken = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        writeTask?.cancel()
        writeTask = nil
        stream.onData = nil
        stream.onDisconnect = nil
        stream.disconnect()
        work?.continuation.resume(throwing: error)
    }
}
