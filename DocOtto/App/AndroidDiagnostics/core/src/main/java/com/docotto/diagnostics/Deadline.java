package com.docotto.diagnostics;

import java.util.concurrent.TimeUnit;

/** Monotonic deadline shared by all waits in one operation. */
public final class Deadline {
    private final long endNanos;

    private Deadline(long milliseconds) {
        endNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(milliseconds);
    }

    public static Deadline afterMillis(long milliseconds) throws DiagnosticException {
        if (milliseconds < 1 || milliseconds > 120000) {
            throw new DiagnosticException(DiagnosticException.Kind.INVALID_CONFIGURATION,
                    "Timeout must be between 1 and 120000 milliseconds.");
        }
        return new Deadline(milliseconds);
    }

    public long remainingMillis() throws DiagnosticException {
        long remaining = endNanos - System.nanoTime();
        if (remaining <= 0) throw DiagnosticException.timeout();
        return (remaining + 999999) / 1000000;
    }
}
