package com.docotto.diagnostics;

import java.util.Arrays;
import java.util.List;
import java.util.Locale;

public final class CanConfiguration {
    public enum BitRate { KBPS_500, KBPS_250 }
    public final int requestId;
    public final int responseId;
    public final BitRate bitRate;

    /** No default ECU IDs: ENET address 12 is not a CAN route. */
    public CanConfiguration(int requestId, int responseId, BitRate bitRate)
            throws DiagnosticException {
        if (requestId < 0 || requestId > 0x7FF || responseId < 0 || responseId > 0x7FF ||
                requestId == responseId || requestId == 0x7DF || bitRate == null) {
            throw new DiagnosticException(DiagnosticException.Kind.INVALID_CONFIGURATION,
                    "Use distinct physical 11-bit CAN IDs and an explicit CAN bit rate.");
        }
        this.requestId = requestId;
        this.responseId = responseId;
        this.bitRate = bitRate;
    }

    List<String> setupCommands() {
        String tx = String.format(Locale.ROOT, "%03X", requestId);
        String rx = String.format(Locale.ROOT, "%03X", responseId);
        return Arrays.asList("ATE0", "ATL0", "ATS1", "ATH1", "ATD0",
                bitRate == BitRate.KBPS_500 ? "ATSP6" : "ATSP8",
                "ATCEA", "ATCAF0", "ATCFC1", "ATSH" + tx, "ATCRA" + rx,
                "ATFCSH" + tx, "ATFCSD300000", "ATFCSM1", "ATAT0", "ATSTFF");
    }
}
