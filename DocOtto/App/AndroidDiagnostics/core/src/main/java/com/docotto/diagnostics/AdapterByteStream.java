package com.docotto.diagnostics;

import java.io.IOException;

/**
 * One selected BLE UART-style adapter. Methods block on a worker, obey their
 * timeout, and respond to interruption. close() must unblock every pending wait.
 * Notification boundaries are not diagnostic-message boundaries.
 */
public interface AdapterByteStream extends AutoCloseable {
    void connect(long timeoutMillis) throws IOException, InterruptedException;
    void write(byte[] bytes, long timeoutMillis) throws IOException, InterruptedException;
    byte[] read(long timeoutMillis) throws IOException, InterruptedException;
    /** Returns null if no notification is queued; never waits. */
    byte[] poll() throws IOException;
    @Override void close();
}
