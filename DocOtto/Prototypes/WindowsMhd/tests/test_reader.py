"""Protocol behavior tests using independent wire fixtures and local sockets."""

import json
from pathlib import Path
import socket
import struct
import tempfile
import threading
import time
import unittest

import doc_otto
from reader import (DiagnosticError, EnetClient, NegativeResponse, Trace,
                    parse_dtcs, parse_identification, parse_vin, scan, summary)


VIN = "WBA00000000000001"  # Synthetic fixture, not a customer's VIN.
VIN_RESPONSE = b"\x62\xf1\x90" + VIN.encode("ascii")
IDENTIFICATION = b"DIAGADR10BMWMAC001122334455BMWVIN" + VIN.encode("ascii")


def wire(body, control=1):
    return len(body).to_bytes(4, "big") + control.to_bytes(2, "big") + body


def ecu(payload, source=0x12, destination=0xF4):
    return wire(bytes([source, destination]) + payload)


def read_exact(sock, size):
    data = b""
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise EOFError("Client closed the test connection")
        data += part
    return data


def receive_request(sock):
    header = read_exact(sock, 6)
    length = int.from_bytes(header[:4], "big")
    if header[4:6] != b"\x00\x01" or length > 1024:
        raise AssertionError("Unexpected request frame")
    body = read_exact(sock, length)
    if body[:2] != b"\xf4\x12":
        raise AssertionError("Unexpected tester / DME addresses")
    return body[2:]


class Gateway:
    def __init__(self, handler, connections=1):
        self.handler, self.connections = handler, connections
        self.requests, self.errors = [], []

    def __enter__(self):
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen()
        self.listener.settimeout(3)
        self.port = self.listener.getsockname()[1]

        def serve():
            try:
                for index in range(self.connections):
                    connection, _ = self.listener.accept()
                    with connection:
                        connection.settimeout(2)
                        self.handler(connection, self.requests, index)
            except Exception as exc:
                self.errors.append(exc)
        self.thread = threading.Thread(target=serve, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.thread.join(4)
        self.listener.close()
        if self.thread.is_alive():
            raise AssertionError("Simulated gateway did not finish")
        if self.errors:
            raise self.errors[0]


def normal_handler(dtc_response):
    def handler(sock, requests, index):
        requests.append(receive_request(sock))
        sock.sendall(ecu(VIN_RESPONSE))
        requests.append(receive_request(sock))
        sock.sendall(ecu(dtc_response))
    return handler


class ParsingTests(unittest.TestCase):
    def test_vin_validation(self):
        self.assertEqual(parse_vin(VIN_RESPONSE), VIN)
        for data in (b"", VIN_RESPONSE[:-1], b"\x62\xf1\x90" + b"I" * 17):
            with self.subTest(data=data), self.assertRaises(DiagnosticError):
                parse_vin(data)

    def test_dtc_codes_and_status(self):
        availability, faults = parse_dtcs(bytes.fromhex("59 02 FF 12 34 56 09 AB CD EF 04"))
        self.assertEqual(availability, 255)
        self.assertEqual([fault["code"] for fault in faults], ["123456", "ABCDEF"])
        self.assertEqual(faults[0]["status_flags"], ["Test failed", "Confirmed"])
        self.assertEqual(faults[1]["status_flags"], ["Pending"])

    def test_empty_success_requires_supported_status(self):
        self.assertEqual(parse_dtcs(bytes.fromhex("59 02 FF")), (255, []))
        with self.assertRaises(DiagnosticError):
            parse_dtcs(bytes.fromhex("59 02 00"))

    def test_malformed_or_out_of_scope_records_do_not_become_no_codes(self):
        for data in ("59 02", "59 02 FF 12 34", "59 02 FF 12 34 56 01",
                     "59 02 FF 00 00 00 08", "59 02 FF 12 34 56 08 12 34 56 08"):
            with self.subTest(data=data), self.assertRaises(DiagnosticError):
                parse_dtcs(bytes.fromhex(data))

    def test_zero_padding_record(self):
        self.assertEqual(parse_dtcs(bytes.fromhex("59 02 FF 00 00 00 00")), (255, []))

    def test_discovery_frame_validation(self):
        packet = wire(IDENTIFICATION, 0x11)
        identity = parse_identification(packet, "127.0.0.1")
        self.assertEqual(identity["vin"], VIN)
        for invalid in (packet[:-1], packet + b"X", wire(IDENTIFICATION, 1), b"x"):
            self.assertIsNone(parse_identification(invalid, "127.0.0.1"))


class NetworkTests(unittest.TestCase):
    def test_full_scan_reads_only_vin_and_dtc_and_serializes_trace(self):
        with Gateway(normal_handler(bytes.fromhex("59 02 FF 12 34 56 08"))) as gateway:
            report = scan("127.0.0.1", port=gateway.port, timeout=0.5)
        self.assertEqual(gateway.requests, [bytes.fromhex("22 F1 90"), bytes.fromhex("19 02 0C")])
        self.assertEqual(report["vin"], VIN)
        self.assertTrue(report["tcp_connected"])
        self.assertEqual(report["dtc_status"], "success")
        self.assertEqual(report["faults"][0]["code"], "123456")
        self.assertIn("received", summary(report))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scan.json"
            doc_otto.save_report(report, path)
            restored = json.loads(path.read_text())
        self.assertEqual(restored, report)
        self.assertTrue(any(event.get("direction") == "rx" for event in report["trace"]))

    def test_empty_scan_success_is_distinct_from_failure(self):
        with Gateway(normal_handler(bytes.fromhex("59 02 FF"))) as gateway:
            report = scan("127.0.0.1", port=gateway.port, timeout=0.5)
        self.assertEqual(report["dtc_status"], "success")
        self.assertEqual(report["faults"], [])
        self.assertIn("No pending", summary(report))

    def test_fragmented_frames_ack_pending_and_unrelated_ecu_are_handled(self):
        def handler(sock, requests, index):
            requests.append(receive_request(sock))
            for part in (ecu(VIN_RESPONSE)[:2], ecu(VIN_RESPONSE)[2:7], ecu(VIN_RESPONSE)[7:]):
                sock.sendall(part)
                time.sleep(0.01)
            requests.append(receive_request(sock))
            packets = (wire(b"\xf4\x12\x19\x02\x0c", 2)
                       + ecu(bytes.fromhex("59 02 FF FE DC BA 08"), source=0x10)
                       + ecu(bytes.fromhex("7F 19 78"))
                       + ecu(bytes.fromhex("59 02 FF 12 34 56 08")))
            sock.sendall(packets)  # Multiple frames in a single TCP write.
        with Gateway(handler) as gateway:
            report = scan("127.0.0.1", port=gateway.port, timeout=0.5)
        self.assertEqual(report["dtc_status"], "success")
        self.assertEqual([fault["code"] for fault in report["faults"]], ["123456"])

    def test_negative_response_is_error_not_no_codes(self):
        with Gateway(normal_handler(bytes.fromhex("7F 19 22"))) as gateway:
            report = scan("127.0.0.1", port=gateway.port, timeout=0.5)
        self.assertEqual(report["dtc_status"], "error")
        self.assertIsNone(report["faults"])
        self.assertIn("conditions not correct", report["errors"][-1])

    def test_ack_only_times_out_and_does_not_claim_success(self):
        def handler(sock, requests, index):
            requests.append(receive_request(sock))
            sock.sendall(ecu(VIN_RESPONSE))
            requests.append(receive_request(sock))
            sock.sendall(wire(b"\xf4\x12", 2))
            time.sleep(0.25)
        with Gateway(handler) as gateway:
            report = scan("127.0.0.1", port=gateway.port, timeout=0.1)
        self.assertTrue(report["tcp_connected"])
        self.assertEqual(report["dtc_status"], "error")
        self.assertIsNone(report["faults"])
        self.assertIn("unknown", summary(report))

    def test_truncated_response_is_error(self):
        def handler(sock, requests, index):
            receive_request(sock)
            sock.sendall(ecu(VIN_RESPONSE))
            receive_request(sock)
            sock.sendall(ecu(bytes.fromhex("59 02 FF 12 34 56 08"))[:-2])
        with Gateway(handler) as gateway:
            report = scan("127.0.0.1", port=gateway.port, timeout=0.5)
        self.assertEqual(report["dtc_status"], "error")
        self.assertIsNone(report["faults"])

    def test_vin_rejection_does_not_prevent_valid_code_read(self):
        def handler(sock, requests, index):
            requests.append(receive_request(sock))
            sock.sendall(ecu(bytes.fromhex("7F 22 31")))
            requests.append(receive_request(sock))
            sock.sendall(ecu(bytes.fromhex("59 02 FF")))
        with Gateway(handler) as gateway:
            report = scan("127.0.0.1", port=gateway.port, timeout=0.5)
        self.assertEqual(report["vin_status"], "error")
        self.assertEqual(report["dtc_status"], "success")

    def test_vin_connection_failure_reconnects_before_code_read(self):
        def handler(sock, requests, index):
            request = receive_request(sock)
            requests.append(request)
            if index == 0:
                sock.sendall(ecu(VIN_RESPONSE)[:8])
            else:
                sock.sendall(ecu(bytes.fromhex("59 02 FF")))
        with Gateway(handler, connections=2) as gateway:
            report = scan("127.0.0.1", port=gateway.port, timeout=0.5)
        self.assertEqual(gateway.requests, [bytes.fromhex("22 F1 90"), bytes.fromhex("19 02 0C")])
        self.assertEqual(report["dtc_status"], "success")
        self.assertEqual(report["vin_status"], "error")

    def test_gateway_error_is_not_a_diagnostic_result(self):
        def handler(sock, requests, index):
            receive_request(sock)
            sock.sendall(ecu(VIN_RESPONSE))
            receive_request(sock)
            sock.sendall(wire(b"", 0x43))
        with Gateway(handler) as gateway:
            report = scan("127.0.0.1", port=gateway.port, timeout=0.5)
        self.assertIsNone(report["faults"])
        self.assertIn("0043", report["errors"][-1])

    def test_request_allowlist_rejects_clear_and_session_changes(self):
        client = EnetClient("127.0.0.1", Trace())
        for payload in (bytes.fromhex("14 FF FF FF"), bytes.fromhex("10 03"), b"", bytes.fromhex("22 F1 91")):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                client.request(payload)

    def test_discovery_then_scan_end_to_end(self):
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.bind(("127.0.0.1", 0))
        udp.settimeout(2)
        discovery_port = udp.getsockname()[1]
        errors = []

        def responder():
            try:
                request, sender = udp.recvfrom(1024)
                self.assertEqual(request, bytes.fromhex("00 00 00 00 00 11"))
                udp.sendto(wire(IDENTIFICATION, 0x11), sender)
            except Exception as exc:
                errors.append(exc)
        thread = threading.Thread(target=responder, daemon=True)
        thread.start()
        try:
            with Gateway(normal_handler(bytes.fromhex("59 02 FF"))) as gateway:
                report = scan(bind_ip="127.0.0.1", port=gateway.port, timeout=0.5,
                              discovery_destination="127.0.0.1", discovery_port=discovery_port)
            thread.join(3)
        finally:
            udp.close()
        self.assertFalse(errors)
        self.assertEqual(report["host"], "127.0.0.1")
        self.assertEqual(report["dtc_status"], "success")
        self.assertEqual(report["discovery"][0]["vin"], VIN)

    def test_invalid_parameters_fail_without_network_success(self):
        for arguments in ({"host": "not-an-ip"}, {"host": "127.0.0.1", "timeout": float("nan")},
                          {"host": "127.0.0.1", "bind_ip": "invalid"}):
            with self.subTest(arguments=arguments):
                report = scan(**arguments)
                self.assertFalse(report["tcp_connected"])
                self.assertIsNone(report["faults"])
                self.assertEqual(report["dtc_status"], "error")


if __name__ == "__main__":
    unittest.main()
