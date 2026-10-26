import Foundation

/// Classical CAN, 11-bit identifiers, normal ISO-TP addressing only.
/// The adapter sends flow-control frames; this parser validates/reassembles replies.
public struct ISOTPAssembler {
    private var remainingLength: Int?
    private var payload: [UInt8] = []
    private var nextSequence: UInt8 = 1

    public init() {}

    public mutating func consume(_ frame: [UInt8]) throws -> [UInt8]? {
        guard (1...8).contains(frame.count) else {
            throw DiagnosticError.malformedResponse("CAN frame must contain 1...8 bytes.")
        }
        switch frame[0] >> 4 {
        case 0:
            guard remainingLength == nil else {
                throw DiagnosticError.malformedResponse("Single frame interrupted a multiline reply.")
            }
            let length = Int(frame[0] & 0x0F)
            guard (1...7).contains(length), frame.count >= length + 1 else {
                throw DiagnosticError.malformedResponse("Invalid single-frame length.")
            }
            return Array(frame[1...length])
        case 1:
            guard remainingLength == nil, frame.count == 8 else {
                throw DiagnosticError.malformedResponse("Invalid or overlapping first frame.")
            }
            let length = (Int(frame[0] & 0x0F) << 8) | Int(frame[1])
            guard (8...4095).contains(length) else {
                throw DiagnosticError.malformedResponse("Unsupported ISO-TP message length.")
            }
            remainingLength = length
            payload = Array(frame.dropFirst(2))
            nextSequence = 1
            return nil
        case 2:
            guard let length = remainingLength, frame.count >= 2,
                  frame[0] & 0x0F == nextSequence else {
                throw DiagnosticError.malformedResponse("Missing, duplicate, or out-of-order CAN frame.")
            }
            let needed = length - payload.count
            guard frame.count - 1 >= min(7, needed) else {
                throw DiagnosticError.malformedResponse("Short consecutive frame.")
            }
            payload += frame.dropFirst().prefix(needed)
            nextSequence = (nextSequence + 1) & 0x0F
            if payload.count == length {
                let complete = payload
                payload = []
                remainingLength = nil
                return complete
            }
            return nil
        default:
            throw DiagnosticError.malformedResponse("Unexpected ISO-TP frame type.")
        }
    }

    public func finish() throws {
        guard remainingLength == nil else {
            throw DiagnosticError.malformedResponse("Truncated ISO-TP response.")
        }
    }
}
