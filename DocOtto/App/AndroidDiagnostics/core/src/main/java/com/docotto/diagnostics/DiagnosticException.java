package com.docotto.diagnostics;

import java.io.IOException;

/** Failed reads never represent an empty successful fault list. */
public final class DiagnosticException extends IOException {
    private static final long serialVersionUID = 1L;
    public enum Kind {
        INVALID_CONFIGURATION, MALFORMED_RESPONSE, ADAPTER, NEGATIVE_RESPONSE,
        RESPONSE_PENDING, TIMEOUT, DISCONNECTED, BUSY
    }

    public final Kind kind;
    public final int service;
    public final int reason;

    public DiagnosticException(Kind kind, String message) {
        this(kind, message, -1, -1);
    }

    private DiagnosticException(Kind kind, String message, int service, int reason) {
        super(message);
        this.kind = kind;
        this.service = service;
        this.reason = reason;
    }

    public static DiagnosticException rejected(int service, int reason) {
        return new DiagnosticException(Kind.NEGATIVE_RESPONSE,
                String.format(java.util.Locale.ROOT, "ECU rejected service %02X (reason %02X).",
                        service, reason), service, reason);
    }

    static DiagnosticException malformed(String message) {
        return new DiagnosticException(Kind.MALFORMED_RESPONSE, message);
    }

    public static DiagnosticException disconnected() {
        return new DiagnosticException(Kind.DISCONNECTED,
                "Adapter disconnected. Fault-code status is unknown.");
    }

    public static DiagnosticException timeout() {
        return new DiagnosticException(Kind.TIMEOUT,
                "Diagnostic operation timed out. Fault-code status is unknown.");
    }

    static void checkInterrupted() throws InterruptedException {
        if (Thread.currentThread().isInterrupted()) {
            throw new InterruptedException("Diagnostic operation cancelled.");
        }
    }
}
