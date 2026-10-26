package com.docotto.diagnostics;

/** The only vehicle requests exposed by the diagnostic transport. */
public enum DmeRequest {
    VIN(new byte[] {0x22, (byte) 0xF1, (byte) 0x90}),
    PENDING_AND_CONFIRMED_FAULTS(new byte[] {0x19, 0x02, 0x0C});

    private final byte[] payload;
    DmeRequest(byte[] payload) { this.payload = payload.clone(); }
    public byte[] bytes() { return payload.clone(); }
}
