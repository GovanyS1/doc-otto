package com.docotto.diagnostics;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CancellationException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/** Dependency-free JVM tests. No Android classes, radio, adapter, or vehicle used. */
public final class DiagnosticsTests {
    private interface Checked { void run() throws Exception; }
    private interface OnWrite { void run(byte[] bytes, long timeout) throws IOException, InterruptedException; }
    private static int passed;
    private static final String VIN_REPLY =
            "7E8 10 14 62 F1 90 57 42 41\r" +
            "7E8 21 30 30 30 30 30 30 30\r" +
            "7E8 22 30 30 30 30 30 30 30\r";
    private static final String DTC_REPLY = "7E8 07 59 02 FF 21 A0 2D 27\r";
    private static final String EMPTY_REPLY = "7E8 03 59 02 FF 00 00 00 00\r";

    private static byte[] hex(String text) throws DiagnosticException { return Hex.decode(text); }
    private static void check(boolean condition, String detail) {
        if (!condition) throw new AssertionError(detail);
    }
    private static void equal(Object actual, Object expected) {
        check(expected == null ? actual == null : expected.equals(actual),
                "Expected " + expected + ", got " + actual);
    }
    private static void bytes(byte[] actual, byte[] expected) {
        check(Arrays.equals(actual, expected), "Different byte arrays");
    }
    private static void test(String name, Checked body) throws Exception {
        body.run();
        passed++;
        System.out.println("PASS " + name);
    }
    private static void fails(Checked body) throws Exception {
        try { body.run(); } catch (DiagnosticException expected) { return; }
        throw new AssertionError("Expected diagnostic failure.");
    }
    private static void kind(DiagnosticException.Kind expected, Checked body) throws Exception {
        try { body.run(); } catch (DiagnosticException error) { equal(error.kind, expected); return; }
        throw new AssertionError("Expected diagnostic failure: " + expected);
    }
    private static void shutdown(ExecutorService worker) throws InterruptedException {
        worker.shutdownNow();
        check(worker.awaitTermination(1, TimeUnit.SECONDS), "Worker did not terminate.");
    }

    private static final class Event {
        final byte[] data;
        final IOException error;
        Event(byte[] data, IOException error) { this.data = data; this.error = error; }
    }

    private static final class FakeStream implements AdapterByteStream {
        final BlockingQueue<Event> incoming = new LinkedBlockingQueue<>();
        final List<byte[]> writes = Collections.synchronizedList(new ArrayList<>());
        final CountDownLatch writeStarted = new CountDownLatch(1);
        final CountDownLatch closedSignal = new CountDownLatch(1);
        final CountDownLatch writeAck = new CountDownLatch(1);
        volatile boolean connected;
        volatile IOException failure;
        volatile boolean holdWrite;
        OnWrite onWrite;

        @Override public void connect(long timeout) { connected = true; }
        @Override public void write(byte[] value, long timeout) throws IOException, InterruptedException {
            writes.add(value.clone());
            writeStarted.countDown();
            if (onWrite != null) onWrite.run(value, timeout);
            if (holdWrite && !writeAck.await(timeout, TimeUnit.MILLISECONDS)) {
                throw DiagnosticException.timeout();
            }
            if (failure != null) throw failure;
        }
        @Override public byte[] read(long timeout) throws IOException, InterruptedException {
            if (failure != null) throw failure;
            Event event = incoming.poll(timeout, TimeUnit.MILLISECONDS);
            if (event == null) throw DiagnosticException.timeout();
            if (event.error != null) throw event.error;
            return event.data;
        }
        @Override public byte[] poll() throws IOException {
            if (failure != null) throw failure;
            Event event = incoming.poll();
            if (event == null) return null;
            if (event.error != null) throw event.error;
            return event.data;
        }
        void emit(String value) { emit(value.getBytes(StandardCharsets.US_ASCII)); }
        void emit(byte[] value) { incoming.offer(new Event(value.clone(), null)); }
        @Override public void close() {
            connected = false;
            failure = DiagnosticException.disconnected();
            incoming.clear();
            incoming.offer(new Event(null, failure));
            writeAck.countDown();
            closedSignal.countDown();
        }
    }

    private static final class FakeCommands implements AdapterCommandChannel {
        final List<String> commands = new ArrayList<>();
        final Map<String, String> replies = new HashMap<>();
        boolean connected;
        @Override public void connect() { connected = true; }
        @Override public String command(String text) throws IOException {
            commands.add(text);
            if (replies.containsKey(text)) return replies.get(text);
            if (text.equals("ATZ")) return "ELM327 v2.3\r";
            if (text.startsWith("AT")) return "OK\r";
            throw DiagnosticException.timeout();
        }
        @Override public void close() { connected = false; }
    }

    private static final class FakeDme implements DmeTransport {
        boolean closed;
        int requests;
        DiagnosticException vinFailure;
        boolean holdOpen;
        final CountDownLatch openStarted = new CountDownLatch(1);
        @Override public void open() throws InterruptedException {
            openStarted.countDown();
            if (holdOpen) new CountDownLatch(1).await();
        }
        @Override public byte[] request(DmeRequest request) throws IOException {
            requests++;
            if (request == DmeRequest.VIN) {
                if (vinFailure != null) throw vinFailure;
                return hex("62 F1 90 57 42 41 30 30 30 30 30 30 30 30 30 30 30 30 30 30");
            }
            return hex("59 02 FF");
        }
        @Override public void close() { closed = true; }
    }

    private static CanConfiguration config() throws DiagnosticException {
        return new CanConfiguration(0x7E0, 0x7E8, CanConfiguration.BitRate.KBPS_500);
    }

    public static void main(String[] args) throws Exception {
        test("VIN validates identifier, length, and alphabet", () -> {
            equal(Uds.parseVin(hex("62 F1 90 57 42 41 30 30 30 30 30 30 30 30 30 30 30 30 30 30")),
                    "WBA00000000000000");
            fails(() -> Uds.parseVin(hex("62 F1 90 57")));
            fails(() -> Uds.parseVin(hex("62 F1 90 57 42 41 30 30 30 30 30 30 30 30 30 30 30 30 30 49")));
        });
        test("fault 21A02D and status 27", () -> {
            Diagnostics.FaultRead read = Uds.parseFaults(hex("59 02 FF 21 A0 2D 27"));
            equal(read.faults.get(0).code, "21A02D");
            equal(read.faults.get(0).rawStatus, 0x27);
            equal(read.faults.get(0).statusLabels(), Arrays.asList("Test failed",
                    "Failed this operating cycle", "Pending", "Test failed since clearing"));
        });
        test("empty success requires status support", () -> {
            check(Uds.parseFaults(hex("59 02 FF")).faults.isEmpty(), "Expected empty success.");
            fails(() -> Uds.parseFaults(hex("59 02 03")));
            fails(() -> Uds.parseFaults(hex("59 02")));
        });
        test("partial support is explicitly reported", () -> {
            Diagnostics.FaultRead read = Uds.parseFaults(hex("59 02 04 21 A0 2D 27"));
            equal(read.evaluatedStatusMask(), 4);
            equal(read.unavailableStatusMask(), 8);
            equal(read.faults.get(0).statusLabels(), Arrays.asList("Pending"));
        });
        test("incomplete, duplicate, zero, and out-of-scope records fail", () -> {
            for (String value : Arrays.asList("59 02 FF 21", "59 02 FF 00 00 00 04",
                    "59 02 FF 21 A0 2D 01", "59 02 FF 21 A0 2D 27 21 A0 2D 27")) {
                fails(() -> Uds.parseFaults(hex(value)));
            }
            check(Uds.parseFaults(hex("59 02 FF 00 00 00 00")).faults.isEmpty(), "Zero padding.");
        });
        test("negative response identifies service and reason", () -> {
            try {
                Uds.response(DmeRequest.VIN, Arrays.asList(hex("7F 22 31")));
                throw new AssertionError("Expected rejection.");
            } catch (DiagnosticException error) {
                equal(error.kind, DiagnosticException.Kind.NEGATIVE_RESPONSE);
                equal(error.service, 0x22);
                equal(error.reason, 0x31);
            }
        });
        test("pending only is inconclusive", () ->
            kind(DiagnosticException.Kind.RESPONSE_PENDING,
                    () -> Uds.response(DmeRequest.VIN, Arrays.asList(hex("7F 22 78")))));
        test("pending then positive response succeeds", () -> {
            byte[] finalReply = hex("59 02 FF");
            bytes(Uds.response(DmeRequest.PENDING_AND_CONFIRMED_FAULTS,
                    Arrays.asList(hex("7F 19 78"), finalReply)), finalReply);
        });
        test("unmatched and duplicate UDS replies fail", () -> {
            fails(() -> Uds.response(DmeRequest.VIN, Arrays.asList(hex("59 02 FF"))));
            fails(() -> Uds.response(DmeRequest.VIN, Arrays.asList(hex("7F 19 31"))));
            fails(() -> Uds.response(DmeRequest.VIN, Arrays.asList(hex("7F 22"))));
            fails(() -> Uds.response(DmeRequest.VIN, Collections.emptyList()));
            fails(() -> Uds.response(DmeRequest.PENDING_AND_CONFIRMED_FAULTS,
                    Arrays.asList(hex("59 02 FF"), hex("59 02 FF"))));
        });
        test("request payload cannot be mutated by caller", () -> {
            byte[] request = DmeRequest.VIN.bytes();
            request[0] = 0x04;
            equal(DmeRequest.VIN.bytes()[0], (byte) 0x22);
        });
        test("single-frame ISO-TP removes padding", () -> {
            IsoTpAssembler parser = new IsoTpAssembler();
            bytes(parser.consume(hex("03 59 02 FF 00 00 00 00")), hex("59 02 FF"));
            parser.finish();
        });
        test("multi-frame VIN reassembly", () -> {
            IsoTpAssembler parser = new IsoTpAssembler();
            equal(parser.consume(hex("10 14 62 F1 90 57 42 41")), null);
            equal(parser.consume(hex("21 30 30 30 30 30 30 30")), null);
            byte[] vin = parser.consume(hex("22 30 30 30 30 30 30 30"));
            equal(Uds.parseVin(vin), "WBA00000000000000");
            parser.finish();
        });
        test("ISO-TP sequence wraps from F to 0", () -> {
            IsoTpAssembler parser = new IsoTpAssembler();
            parser.consume(hex("10 78 55 55 55 55 55 55"));
            byte[] result = null;
            int sequence = 1;
            for (int offset = 6; offset < 120; offset += 7) {
                byte[] frame = new byte[1 + Math.min(7, 120 - offset)];
                Arrays.fill(frame, (byte) 0x55);
                frame[0] = (byte) (0x20 | sequence);
                result = parser.consume(frame);
                sequence = (sequence + 1) & 15;
            }
            check(result != null && result.length == 120, "Sequence-wrap result.");
            parser.finish();
        });
        test("missing and short CAN frames are rejected", () -> {
            IsoTpAssembler parser = new IsoTpAssembler();
            parser.consume(hex("10 14 62 F1 90 57 42 41"));
            fails(parser::finish);
            fails(() -> parser.consume(hex("22 00 00 00 00 00 00 00")));
            fails(() -> parser.consume(hex("03 59 02 FF")));
            fails(() -> new IsoTpAssembler().consume(hex("07 59")));
            fails(() -> new IsoTpAssembler().consume(hex("30 00 00")));
            fails(() -> new IsoTpAssembler().consume(hex("21 00 00 00 00 00 00 00")));
        });
        test("wrong ECU and adapter errors never count as no codes", () -> {
            for (String value : Arrays.asList("NO DATA", "CAN ERROR", "OK", "?", "STOPPED",
                    "BUFFER FULL", "7E9 03 59 02 FF 00 00 00 00", "7E8 03 59 02", "")) {
                fails(() -> Elm327Transport.parseCanReply(value, "", 0x7E8));
            }
        });
        test("CAN IDs and timeouts require valid explicit configuration", () -> {
            fails(() -> new CanConfiguration(0x7DF, 0x7E8, CanConfiguration.BitRate.KBPS_500));
            fails(() -> new CanConfiguration(-1, 0x7E8, CanConfiguration.BitRate.KBPS_500));
            fails(() -> new CanConfiguration(0x800, 0x7E8, CanConfiguration.BitRate.KBPS_500));
            fails(() -> new CanConfiguration(0x7E0, 0x7E0, CanConfiguration.BitRate.KBPS_500));
            fails(() -> Deadline.afterMillis(0));
            fails(() -> new PromptCommandChannel(new FakeStream(), 1, 100));
        });
        test("notification fragments assemble through the prompt", () -> {
            FakeStream stream = new FakeStream();
            stream.onWrite = (value, timeout) -> { stream.emit("O"); stream.emit("K\r>"); };
            try (PromptCommandChannel channel = new PromptCommandChannel(stream)) {
                channel.connect();
                equal(channel.command("ATE0"), "OK\r");
                bytes(stream.writes.get(0), "ATE0\r".getBytes(StandardCharsets.US_ASCII));
                equal(channel.trace().get(0).direction, "tx");
                equal(channel.trace().get(1).direction, "rx");
            }
        });
        test("prompt arriving before GATT write completion is preserved", () -> {
            FakeStream stream = new FakeStream();
            stream.holdWrite = true;
            stream.onWrite = (value, timeout) -> stream.emit("OK\r>");
            ExecutorService worker = Executors.newSingleThreadExecutor();
            try (PromptCommandChannel channel = new PromptCommandChannel(stream)) {
                channel.connect();
                Future<String> result = worker.submit(() -> channel.command("ATE0"));
                check(stream.writeStarted.await(1, TimeUnit.SECONDS), "Write never started.");
                check(!result.isDone(), "Must await GATT write completion.");
                stream.writeAck.countDown();
                equal(result.get(1, TimeUnit.SECONDS), "OK\r");
            } finally { shutdown(worker); }
        });
        test("write completion without diagnostic bytes times out", () -> {
            FakeStream stream = new FakeStream();
            PromptCommandChannel channel = new PromptCommandChannel(stream, 50, 100);
            channel.connect();
            kind(DiagnosticException.Kind.TIMEOUT, () -> channel.command("ATI"));
            check(!stream.connected, "Timeout must disconnect.");
            stream.emit("OK\r>");
            kind(DiagnosticException.Kind.DISCONNECTED, () -> channel.command("ATI"));
        });
        test("cancelling a blocked read closes the transport", () -> {
            FakeStream stream = new FakeStream();
            ExecutorService worker = Executors.newSingleThreadExecutor();
            try (PromptCommandChannel channel = new PromptCommandChannel(stream)) {
                channel.connect();
                Future<String> future = worker.submit(() -> channel.command("ATI"));
                check(stream.writeStarted.await(1, TimeUnit.SECONDS), "Write never started.");
                check(future.cancel(true), "Cancellation did not succeed.");
                check(stream.closedSignal.await(1, TimeUnit.SECONDS), "Cancellation did not close stream.");
            } finally { shutdown(worker); }
        });
        test("cancelling an unacknowledged write closes the transport", () -> {
            FakeStream stream = new FakeStream();
            stream.holdWrite = true;
            ExecutorService worker = Executors.newSingleThreadExecutor();
            try (PromptCommandChannel channel = new PromptCommandChannel(stream)) {
                channel.connect();
                Future<String> future = worker.submit(() -> channel.command("ATI"));
                check(stream.writeStarted.await(1, TimeUnit.SECONDS), "Write never started.");
                future.cancel(true);
                check(stream.closedSignal.await(1, TimeUnit.SECONDS), "Write cancellation leaked stream.");
            } finally { shutdown(worker); }
        });
        test("concurrent commands are rejected without disturbing the first", () -> {
            FakeStream stream = new FakeStream();
            ExecutorService worker = Executors.newSingleThreadExecutor();
            try (PromptCommandChannel channel = new PromptCommandChannel(stream)) {
                channel.connect();
                Future<String> future = worker.submit(() -> channel.command("ATI"));
                check(stream.writeStarted.await(1, TimeUnit.SECONDS), "Write never started.");
                kind(DiagnosticException.Kind.BUSY, () -> channel.command("ATE0"));
                stream.emit("ELM327 v2.3\r>");
                equal(future.get(1, TimeUnit.SECONDS), "ELM327 v2.3\r");
            } finally { shutdown(worker); }
        });
        test("disconnect unblocks a pending read", () -> {
            FakeStream stream = new FakeStream();
            stream.onWrite = (value, timeout) -> stream.close();
            PromptCommandChannel channel = new PromptCommandChannel(stream);
            channel.connect();
            kind(DiagnosticException.Kind.DISCONNECTED, () -> channel.command("ATI"));
        });
        test("oversized non-ASCII and ambiguous prompt replies fail", () -> {
            byte[] oversized = new byte[32769];
            Arrays.fill(oversized, (byte) 'A');
            for (byte[] reply : Arrays.asList(oversized, new byte[] {(byte) 0xFF},
                    "OK>NO DATA>".getBytes(StandardCharsets.US_ASCII))) {
                FakeStream stream = new FakeStream();
                stream.onWrite = (value, timeout) -> stream.emit(reply);
                PromptCommandChannel channel = new PromptCommandChannel(stream);
                channel.connect();
                fails(() -> channel.command("ATI"));
                check(!stream.connected, "Malformed reply must disconnect.");
            }
        });
        test("command injection is rejected before sending", () -> {
            FakeStream stream = new FakeStream();
            try (PromptCommandChannel channel = new PromptCommandChannel(stream)) {
                channel.connect();
                kind(DiagnosticException.Kind.INVALID_CONFIGURATION, () -> channel.command("ATI\r04"));
                check(stream.writes.isEmpty(), "Injected command was written.");
            }
        });
        test("unsolicited reply invalidates a used session", () -> {
            FakeStream stream = new FakeStream();
            stream.onWrite = (value, timeout) -> stream.emit("OK\r>");
            PromptCommandChannel channel = new PromptCommandChannel(stream);
            channel.connect();
            channel.command("ATE0");
            stream.emit("7E8 03 59 02 FF\r>");
            kind(DiagnosticException.Kind.MALFORMED_RESPONSE, () -> channel.command("ATI"));
            check(!stream.connected, "Unsolicited reply must invalidate stream.");
        });
        test("wire trace is bounded", () -> {
            FakeStream stream = new FakeStream();
            stream.onWrite = (value, timeout) -> stream.emit("OK\r>");
            try (PromptCommandChannel channel = new PromptCommandChannel(stream)) {
                channel.connect();
                for (int i = 0; i < 40; i++) channel.command("ATE0");
                equal(channel.trace().size(), 64);
            }
        });
        test("full reader through simulated BLE ELM CAN and UDS", () -> {
            FakeStream stream = new FakeStream();
            List<String> commands = new ArrayList<>();
            stream.onWrite = (value, timeout) -> {
                String command = new String(value, StandardCharsets.US_ASCII).trim();
                commands.add(command);
                String reply;
                if (command.equals("ATZ")) reply = "ATZ\rELM327 v2.3\r>";
                else if (command.equals("0322F19000000000")) reply = VIN_REPLY + ">";
                else if (command.equals("0319020C00000000")) reply = DTC_REPLY + ">";
                else reply = "OK\r>";
                for (byte part : reply.getBytes(StandardCharsets.US_ASCII)) stream.emit(new byte[] {part});
            };
            PromptCommandChannel channel = new PromptCommandChannel(stream);
            CanConfiguration config = config();
            Diagnostics.EngineScan result = new DmeReader(
                    () -> new Elm327Transport(channel, config)).scan();
            equal(result.vin, "WBA00000000000000");
            equal(result.faultRead.faults.get(0).code, "21A02D");
            check(!stream.connected, "Scan must close connection.");
            List<String> vehicle = new ArrayList<>();
            for (String command : commands) if (!command.startsWith("AT")) vehicle.add(command);
            equal(vehicle, Arrays.asList("0322F19000000000", "0319020C00000000"));
            check(commands.contains("ATFCSH7E0") && commands.contains("ATFCSD300000") &&
                    commands.contains("ATFCSM1"), "Explicit flow control.");
        });
        test("unsupported setup stops before diagnostic requests", () -> {
            FakeCommands channel = new FakeCommands();
            channel.replies.put("ATCAF0", "?\r");
            Elm327Transport transport = new Elm327Transport(channel, config());
            kind(DiagnosticException.Kind.ADAPTER, transport::open);
            for (String command : channel.commands) check(command.startsWith("AT"), "Vehicle request was sent.");
            check(!channel.connected, "Rejected setup must disconnect.");
        });
        test("valid empty response is distinct from NO DATA", () -> {
            FakeCommands channel = new FakeCommands();
            channel.replies.put("0319020C00000000", EMPTY_REPLY);
            try (Elm327Transport transport = new Elm327Transport(channel, config())) {
                transport.open();
                check(Uds.parseFaults(transport.request(DmeRequest.PENDING_AND_CONFIRMED_FAULTS))
                        .faults.isEmpty(), "Expected positive empty result.");
            }
            FakeCommands rejected = new FakeCommands();
            rejected.replies.put("0319020C00000000", "NO DATA\r");
            Elm327Transport transport = new Elm327Transport(rejected, config());
            transport.open();
            kind(DiagnosticException.Kind.ADAPTER,
                    () -> transport.request(DmeRequest.PENDING_AND_CONFIRMED_FAULTS));
        });
        test("complete VIN rejection keeps ELM synchronized", () -> {
            FakeCommands channel = new FakeCommands();
            channel.replies.put("0322F19000000000", "7E8 03 7F 22 31 00 00 00 00\r");
            channel.replies.put("0319020C00000000", EMPTY_REPLY);
            CanConfiguration config = config();
            Diagnostics.EngineScan result = new DmeReader(() -> new Elm327Transport(channel, config)).scan();
            equal(result.vin, null);
            check(result.vinRejection != null && result.faultRead.faults.isEmpty(), "Expected code read.");
            check(!channel.connected, "Scan must close session.");
        });
        test("VIN timeout stops before code read", () -> {
            FakeDme transport = new FakeDme();
            transport.vinFailure = DiagnosticException.timeout();
            kind(DiagnosticException.Kind.TIMEOUT, () -> new DmeReader(() -> transport).scan());
            equal(transport.requests, 1);
            check(transport.closed, "Failed scan must close session.");
        });
        test("transport factory failure releases reader", () -> {
            boolean[] fail = {true};
            FakeDme transport = new FakeDme();
            DmeReader reader = new DmeReader(() -> {
                if (fail[0]) throw DiagnosticException.disconnected();
                return transport;
            });
            kind(DiagnosticException.Kind.DISCONNECTED, reader::scan);
            fail[0] = false;
            check(reader.scan().faultRead.faults.isEmpty(), "Reader remained busy.");
        });
        test("busy reader and scan cancellation clean up", () -> {
            FakeDme transport = new FakeDme();
            transport.holdOpen = true;
            DmeReader reader = new DmeReader(() -> transport);
            ExecutorService worker = Executors.newSingleThreadExecutor();
            try {
                Future<Diagnostics.EngineScan> future = worker.submit(() -> reader.scan());
                check(transport.openStarted.await(1, TimeUnit.SECONDS), "Open never started.");
                kind(DiagnosticException.Kind.BUSY, reader::scan);
                future.cancel(true);
                try { future.get(); throw new AssertionError("Expected cancellation."); }
                catch (CancellationException expected) { /* Expected. */ }
            } finally { shutdown(worker); }
            check(transport.closed, "Cancelled scan must close session.");
        });
        test("interrupted scan does not create a transport", () -> {
            boolean[] created = {false};
            DmeReader reader = new DmeReader(() -> { created[0] = true; return new FakeDme(); });
            Thread.currentThread().interrupt();
            try {
                reader.scan();
                throw new AssertionError("Expected interruption.");
            } catch (InterruptedException expected) {
                check(!created[0], "Cancelled task created a connection.");
            } finally { Thread.interrupted(); }
        });
        System.out.println("All " + passed + " Android diagnostic core tests passed.");
    }
}
