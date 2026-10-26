package com.docotto.diagnostics;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.locks.ReentrantLock;

/** One prompt-delimited command at a time; failure permanently ends the session. */
public final class PromptCommandChannel implements AdapterCommandChannel {
    private final AdapterByteStream stream;
    private final long timeoutMillis;
    private final long connectionTimeoutMillis;
    private final ReentrantLock operation = new ReentrantLock();
    private final AtomicBoolean closed = new AtomicBoolean();
    private final List<Diagnostics.WireEvent> trace = new ArrayList<>();
    private volatile boolean connected;
    private boolean started;
    private boolean sentCommand;

    public PromptCommandChannel(AdapterByteStream stream) throws DiagnosticException {
        this(stream, 12000, 15000);
    }

    public PromptCommandChannel(AdapterByteStream stream, long timeoutMillis,
                                long connectionTimeoutMillis) throws DiagnosticException {
        if (stream == null || timeoutMillis < 50 || timeoutMillis > 120000 ||
                connectionTimeoutMillis < 1 || connectionTimeoutMillis > 120000) {
            throw new DiagnosticException(DiagnosticException.Kind.INVALID_CONFIGURATION,
                    "Stream and bounded command/connection timeouts are required.");
        }
        this.stream = stream;
        this.timeoutMillis = timeoutMillis;
        this.connectionTimeoutMillis = connectionTimeoutMillis;
    }

    @Override public void connect() throws IOException, InterruptedException {
        enter();
        try {
            if (started || closed.get()) throw DiagnosticException.disconnected();
            started = true;
            DiagnosticException.checkInterrupted();
            stream.connect(connectionTimeoutMillis);
            DiagnosticException.checkInterrupted();
            if (closed.get()) throw DiagnosticException.disconnected();
            connected = true;
        } catch (IOException | InterruptedException error) {
            close();
            throw error;
        } finally {
            operation.unlock();
        }
    }

    @Override public String command(String text) throws IOException, InterruptedException {
        enter();
        try {
            if (!connected || closed.get()) throw DiagnosticException.disconnected();
            if (text == null || text.isEmpty() || text.length() > 64 ||
                    !text.matches("[\\x20-\\x3D\\x3F-\\x7E]+")) {
                throw new DiagnosticException(DiagnosticException.Kind.INVALID_CONFIGURATION,
                        "Command contains invalid ASCII or terminators.");
            }
            DiagnosticException.checkInterrupted();
            Deadline deadline = Deadline.afterMillis(timeoutMillis);
            drainIdleBytes();
            sentCommand = true;
            record("tx", text);
            stream.write((text + "\r").getBytes(StandardCharsets.US_ASCII),
                    deadline.remainingMillis());
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            while (true) {
                DiagnosticException.checkInterrupted();
                if (closed.get()) throw DiagnosticException.disconnected();
                byte[] part = stream.read(deadline.remainingMillis());
                if (part == null) throw DiagnosticException.disconnected();
                if (buffer.size() + part.length > 32768) {
                    throw DiagnosticException.malformed("Oversized adapter reply.");
                }
                for (byte value : part) {
                    if ((value & 0xFF) > 127) {
                        throw DiagnosticException.malformed("Non-ASCII adapter reply.");
                    }
                }
                int prompt = -1;
                for (int i = 0; i < part.length; i++) {
                    if (part[i] == '>') { prompt = buffer.size() + i; break; }
                }
                buffer.write(part, 0, part.length);
                if (prompt == -1) continue;
                byte[] bytes = buffer.toByteArray();
                for (int i = prompt + 1; i < bytes.length; i++) {
                    if (!whitespace(bytes[i])) {
                        throw DiagnosticException.malformed("Unexpected data after the ELM prompt.");
                    }
                }
                DiagnosticException.checkInterrupted();
                if (closed.get()) throw DiagnosticException.disconnected();
                String reply = new String(bytes, 0, prompt, StandardCharsets.US_ASCII);
                record("rx", reply);
                return reply;
            }
        } catch (DiagnosticException error) {
            if (error.kind != DiagnosticException.Kind.INVALID_CONFIGURATION) close();
            throw error;
        } catch (IOException | InterruptedException error) {
            close();
            throw error;
        } finally {
            operation.unlock();
        }
    }

    private void drainIdleBytes() throws IOException {
        int count = 0;
        byte[] part;
        while ((part = stream.poll()) != null) {
            count += part.length;
            if (count > 32768) throw DiagnosticException.malformed("Oversized adapter boot chatter.");
            for (byte value : part) {
                if (sentCommand && !whitespace(value)) {
                    throw DiagnosticException.malformed("Unsolicited adapter bytes.");
                }
            }
        }
    }

    private static boolean whitespace(byte value) {
        return value == 9 || value == 10 || value == 13 || value == 32;
    }

    private void enter() throws DiagnosticException {
        if (operation.isHeldByCurrentThread() || !operation.tryLock()) {
            throw new DiagnosticException(DiagnosticException.Kind.BUSY,
                    "Another command is in progress.");
        }
    }

    private synchronized void record(String direction, String text) {
        if (trace.size() == 64) trace.remove(0);
        trace.add(new Diagnostics.WireEvent(direction, text));
    }

    public synchronized List<Diagnostics.WireEvent> trace() {
        return Collections.unmodifiableList(new ArrayList<>(trace));
    }

    @Override public void close() {
        connected = false;
        if (closed.compareAndSet(false, true)) stream.close();
    }
}
