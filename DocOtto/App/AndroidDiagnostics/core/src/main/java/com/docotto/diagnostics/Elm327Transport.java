package com.docotto.diagnostics;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.locks.ReentrantLock;

public final class Elm327Transport implements DmeTransport {
    private final AdapterCommandChannel channel;
    private final CanConfiguration config;
    private final ReentrantLock operation = new ReentrantLock();
    private volatile boolean ready;

    public Elm327Transport(AdapterCommandChannel channel, CanConfiguration config) {
        if (channel == null || config == null) throw new IllegalArgumentException("Channel/config required.");
        this.channel = channel;
        this.config = config;
    }

    @Override public void open() throws IOException, InterruptedException {
        enter();
        try {
            if (ready) throw new DiagnosticException(DiagnosticException.Kind.BUSY, "Already open.");
            DiagnosticException.checkInterrupted();
            channel.connect();
            // ELM adapter reset only, not a UDS ECU reset or code clearing.
            if (!channel.command("ATZ").toUpperCase(Locale.ROOT).contains("ELM327")) {
                throw new DiagnosticException(DiagnosticException.Kind.ADAPTER,
                        "Expected an ELM327-compatible startup banner.");
            }
            for (String command : config.setupCommands()) {
                DiagnosticException.checkInterrupted();
                String reply = channel.command(command);
                if (!lines(reply, command).equals(Arrays.asList("OK"))) {
                    throw new DiagnosticException(DiagnosticException.Kind.ADAPTER,
                            "Setup command " + command + " was rejected: " + reply);
                }
            }
            DiagnosticException.checkInterrupted();
            ready = true;
        } catch (IOException | InterruptedException error) {
            close();
            throw error;
        } finally {
            operation.unlock();
        }
    }

    @Override public byte[] request(DmeRequest request) throws IOException, InterruptedException {
        enter();
        try {
            if (!ready) throw DiagnosticException.disconnected();
            DiagnosticException.checkInterrupted();
            byte[] payload = request.bytes();
            byte[] frame = new byte[8];
            frame[0] = (byte) payload.length;
            System.arraycopy(payload, 0, frame, 1, payload.length);
            String command = Hex.encode(frame);
            String reply = channel.command(command);
            DiagnosticException.checkInterrupted();
            return Uds.response(request, parseCanReply(reply, command, config.responseId));
        } catch (DiagnosticException error) {
            if (error.kind != DiagnosticException.Kind.NEGATIVE_RESPONSE) close();
            throw error;
        } catch (IOException | InterruptedException error) {
            close();
            throw error;
        } finally {
            operation.unlock();
        }
    }

    private void enter() throws DiagnosticException {
        if (operation.isHeldByCurrentThread() || !operation.tryLock()) throw new DiagnosticException(DiagnosticException.Kind.BUSY,
                "Another adapter operation is in progress.");
    }

    @Override public void close() {
        ready = false;
        channel.close();
    }

    private static List<String> lines(String reply, String echo) {
        List<String> result = new ArrayList<>();
        for (String raw : reply.toUpperCase(Locale.ROOT).split("[\\r\\n]+")) {
            String line = raw.trim();
            if (!line.isEmpty() && !line.replace(" ", "").equals(echo)) result.add(line);
        }
        return result;
    }

    static List<byte[]> parseCanReply(String reply, String echo, int responseId)
            throws DiagnosticException {
        IsoTpAssembler parser = new IsoTpAssembler();
        List<byte[]> messages = new ArrayList<>();
        for (String line : lines(reply, echo)) {
            String compact = line.replaceAll("\\s", "");
            if (compact.length() < 5 || (compact.length() - 3) % 2 != 0 ||
                    !compact.matches("[0-9A-F]+")) {
                throw new DiagnosticException(DiagnosticException.Kind.ADAPTER,
                        "Expected a raw CAN frame, received: " + line);
            }
            int identifier = Integer.parseInt(compact.substring(0, 3), 16);
            if (identifier != responseId) {
                throw DiagnosticException.malformed("Reply came from an unexpected CAN ID.");
            }
            byte[] message = parser.consume(Hex.decode(compact.substring(3)));
            if (message != null) messages.add(message);
        }
        parser.finish();
        if (messages.isEmpty()) throw DiagnosticException.malformed("No complete ECU message.");
        return messages;
    }
}
