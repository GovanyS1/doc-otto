package com.docotto.diagnostics;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

public final class Uds {
    private Uds() {}

    public static byte[] response(DmeRequest request, List<byte[]> messages)
            throws DiagnosticException {
        byte[] result = null;
        boolean pending = false;
        int service = request.bytes()[0] & 0xFF;
        for (byte[] message : messages) {
            if (message.length == 0) throw DiagnosticException.malformed("Empty UDS message.");
            if ((message[0] & 0xFF) == 0x7F) {
                if (message.length != 3 || (message[1] & 0xFF) != service || result != null) {
                    throw DiagnosticException.malformed("Unmatched negative response.");
                }
                if ((message[2] & 0xFF) == 0x78) {
                    pending = true;
                    continue;
                }
                throw DiagnosticException.rejected(service, message[2] & 0xFF);
            }
            boolean match = request == DmeRequest.VIN
                    ? message.length >= 3 && (message[0] & 0xFF) == 0x62 &&
                        (message[1] & 0xFF) == 0xF1 && (message[2] & 0xFF) == 0x90
                    : message.length >= 2 && (message[0] & 0xFF) == 0x59 && message[1] == 0x02;
            if (!match || result != null) {
                throw DiagnosticException.malformed("Unexpected or duplicate UDS response.");
            }
            result = message.clone();
        }
        if (result != null) return result;
        if (pending) throw new DiagnosticException(DiagnosticException.Kind.RESPONSE_PENDING,
                "ECU is still processing. Fault-code status is unknown.");
        throw DiagnosticException.malformed("No matching ECU result.");
    }

    public static String parseVin(byte[] bytes) throws DiagnosticException {
        if (bytes.length != 20 || (bytes[0] & 0xFF) != 0x62 ||
                (bytes[1] & 0xFF) != 0xF1 || (bytes[2] & 0xFF) != 0x90) {
            throw DiagnosticException.malformed("VIN response length or identifier.");
        }
        String vin = new String(bytes, 3, 17, StandardCharsets.US_ASCII);
        if (!vin.matches("[A-HJ-NPR-Z0-9]{17}")) {
            throw DiagnosticException.malformed("VIN must contain 17 valid ASCII characters.");
        }
        return vin;
    }

    public static Diagnostics.FaultRead parseFaults(byte[] bytes) throws DiagnosticException {
        if (bytes.length < 3 || bytes[0] != 0x59 || bytes[1] != 0x02 ||
                (bytes.length - 3) % 4 != 0) {
            throw DiagnosticException.malformed("Fault response has incomplete records.");
        }
        int available = bytes[2] & 0xFF;
        if ((available & 0x0C) == 0) {
            throw DiagnosticException.malformed("ECU supports neither requested status bit.");
        }
        List<Diagnostics.FaultRecord> faults = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (int offset = 3; offset < bytes.length; offset += 4) {
            byte[] record = Arrays.copyOfRange(bytes, offset, offset + 4);
            if (Arrays.equals(record, new byte[4])) continue;
            String code = Hex.encode(Arrays.copyOf(record, 3));
            int status = record[3] & 0xFF;
            if (code.equals("000000") || (status & available & 0x0C) == 0 || !seen.add(code)) {
                throw DiagnosticException.malformed("Invalid, duplicate, or out-of-scope fault.");
            }
            faults.add(new Diagnostics.FaultRecord(code, status, status & available));
        }
        return new Diagnostics.FaultRead(available, faults);
    }
}
