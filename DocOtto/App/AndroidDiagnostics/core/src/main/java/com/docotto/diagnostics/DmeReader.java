package com.docotto.diagnostics;

import java.io.IOException;
import java.util.concurrent.locks.ReentrantLock;

/** Blocking read-only scanner. Run on a worker; Future.cancel(true) interrupts it. */
public final class DmeReader {
    public interface TransportFactory { DmeTransport create() throws IOException; }
    private final TransportFactory factory;
    private final ReentrantLock lock = new ReentrantLock();

    public DmeReader(TransportFactory factory) {
        if (factory == null) throw new IllegalArgumentException("Transport factory is required.");
        this.factory = factory;
    }

    public Diagnostics.EngineScan scan() throws IOException, InterruptedException {
        return scan("test vehicle");
    }

    public Diagnostics.EngineScan scan(String targetLabel) throws IOException, InterruptedException {
        if (lock.isHeldByCurrentThread() || !lock.tryLock()) throw new DiagnosticException(DiagnosticException.Kind.BUSY,
                "Another diagnostic scan is in progress.");
        try {
            DiagnosticException.checkInterrupted();
            long started = System.currentTimeMillis();
            try (DmeTransport transport = factory.create()) {
                DiagnosticException.checkInterrupted();
                transport.open();
                DiagnosticException.checkInterrupted();
                String vin = null;
                String vinRejection = null;
                try {
                    vin = Uds.parseVin(transport.request(DmeRequest.VIN));
                } catch (DiagnosticException error) {
                    if (error.kind != DiagnosticException.Kind.NEGATIVE_RESPONSE ||
                            error.service != 0x22) throw error;
                    vinRejection = error.getMessage();
                }
                DiagnosticException.checkInterrupted();
                Diagnostics.FaultRead read = Uds.parseFaults(
                        transport.request(DmeRequest.PENDING_AND_CONFIRMED_FAULTS));
                DiagnosticException.checkInterrupted();
                return new Diagnostics.EngineScan(started, System.currentTimeMillis(),
                        targetLabel, vin, vinRejection, read);
            }
        } finally {
            lock.unlock();
        }
    }
}
