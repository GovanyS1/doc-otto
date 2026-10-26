package com.docotto.diagnostics;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;

/** Classical CAN, normal ISO-TP addressing; the adapter sends flow-control frames. */
public final class IsoTpAssembler {
    private int length = -1;
    private int nextSequence = 1;
    private final ByteArrayOutputStream payload = new ByteArrayOutputStream();

    /** Returns null until one complete diagnostic message has arrived. */
    public byte[] consume(byte[] frame) throws DiagnosticException {
        if (frame.length < 1 || frame.length > 8) {
            throw DiagnosticException.malformed("CAN frame must contain 1...8 bytes.");
        }
        int kind = (frame[0] & 0xFF) >>> 4;
        if (kind == 0) {
            int size = frame[0] & 15;
            if (length != -1 || size < 1 || size > 7 || frame.length < size + 1) {
                throw DiagnosticException.malformed("Invalid or interrupted single frame.");
            }
            return Arrays.copyOfRange(frame, 1, size + 1);
        }
        if (kind == 1) {
            if (length != -1 || frame.length != 8) {
                throw DiagnosticException.malformed("Invalid or overlapping first frame.");
            }
            int size = ((frame[0] & 15) << 8) | (frame[1] & 0xFF);
            if (size < 8 || size > 4095) {
                throw DiagnosticException.malformed("Unsupported ISO-TP message length.");
            }
            length = size;
            payload.reset();
            payload.write(frame, 2, 6);
            nextSequence = 1;
            return null;
        }
        if (kind == 2) {
            int needed = length - payload.size();
            if (length == -1 || frame.length < 2 || (frame[0] & 15) != nextSequence ||
                    frame.length - 1 < Math.min(7, needed)) {
                throw DiagnosticException.malformed("Missing, short, or out-of-order CAN frame.");
            }
            payload.write(frame, 1, Math.min(needed, frame.length - 1));
            nextSequence = (nextSequence + 1) & 15;
            if (payload.size() == length) {
                byte[] complete = payload.toByteArray();
                payload.reset();
                length = -1;
                return complete;
            }
            return null;
        }
        throw DiagnosticException.malformed("Unexpected ISO-TP frame type.");
    }

    public void finish() throws DiagnosticException {
        if (length != -1) throw DiagnosticException.malformed("Truncated ISO-TP response.");
    }
}
