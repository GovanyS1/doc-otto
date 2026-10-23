"""Small, dependency-free BMW ENET/HSFZ reader. Hardware compatibility is unverified.

Only ReadDataByIdentifier(VIN) and ReadDTCInformation are exposed. No session
changes, clearing, coding, security access, or arbitrary diagnostic commands.
"""

from __future__ import annotations

from datetime import datetime, timezone
import ipaddress
import json
import math
import re
import socket
import struct
import subprocess
import sys
import time
from typing import Callable


DIAGNOSTIC_PORT = 6801
DISCOVERY_PORT = 6811
TESTER = 0xF4
DME = 0x12  # Initial BMW DME address; must be verified on the test vehicle.
VIN_REQUEST = bytes.fromhex("22 F1 90")
DTC_REQUEST = bytes.fromhex("19 02 0C")  # Pending OR confirmed, not every known DTC.
MAX_FRAME = 1024 * 1024
STATUS_NAMES = (
    "Test failed", "Test failed this operating cycle", "Pending", "Confirmed",
    "Test not completed since clearing", "Test failed since clearing",
    "Test not completed this operating cycle", "Warning indicator requested",
)


class DiagnosticError(Exception):
    """A failed diagnostic operation, never an empty successful result."""


class NegativeResponse(DiagnosticError):
    def __init__(self, service: int, reason: int):
        names = {0x10: "general rejection", 0x11: "service not supported",
                 0x12: "subfunction not supported", 0x13: "invalid request format",
                 0x21: "ECU busy", 0x22: "conditions not correct",
                 0x31: "request out of range", 0x33: "security access denied",
                 0x7E: "subfunction unavailable in this session",
                 0x7F: "service unavailable in this session"}
        self.service, self.reason = service, reason
        super().__init__(f"ECU rejected service 0x{service:02X}: "
                         f"{names.get(reason, 'negative response')} (0x{reason:02X}).")


class Trace:
    def __init__(self, notify: Callable[[str], None] | None = None):
        self.events: list[dict] = []
        self.notify = notify or (lambda message: None)

    def add(self, message: str, **fields):
        self.events.append({"time_utc": datetime.now(timezone.utc).isoformat(),
                            "message": message, **fields})
        self.notify(message)


def ipv4(value: str) -> str:
    address = ipaddress.IPv4Address(value)
    if address.is_unspecified or address.is_multicast or address == ipaddress.IPv4Address("255.255.255.255"):
        raise ValueError("Use a specific IPv4 address.")
    return str(address)


def network_interfaces() -> list[dict]:
    """Read Windows interface addresses without changing any network settings."""
    if sys.platform == "win32":
        command = (
            "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
            "Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | "
            "Select-Object InterfaceAlias,IPAddress,PrefixLength | "
            "ConvertTo-Json -Compress"
        )
        try:
            result = subprocess.run(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
                capture_output=True, text=True, encoding="utf-8", errors="replace",
                timeout=8, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                check=True,
            )
            rows = json.loads(result.stdout.lstrip("\ufeff"))
            if isinstance(rows, dict):
                rows = [rows]
            interfaces = []
            for row in rows or []:
                address = ipaddress.IPv4Address(row["IPAddress"])
                if not address.is_loopback and not address.is_unspecified:
                    interfaces.append({"name": row["InterfaceAlias"], "ip": str(address),
                                       "prefix": int(row["PrefixLength"])})
            return sorted(interfaces, key=lambda item: (
                not any(word in item["name"].lower() for word in ("wi-fi", "wifi", "wlan", "wireless")),
                item["name"], item["ip"],
            ))
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
            pass
    # Manual binding is also available through the CLI. No guessed adapter IP.
    try:
        addresses = sorted({info[4][0] for info in socket.getaddrinfo(
            socket.gethostname(), None, socket.AF_INET, socket.SOCK_DGRAM)})
        return [{"name": "Local interface", "ip": address, "prefix": None}
                for address in addresses if not ipaddress.IPv4Address(address).is_loopback]
    except OSError:
        return []


def parse_identification(packet: bytes, host: str) -> dict | None:
    if len(packet) < 6:
        return None
    length, control = struct.unpack(">IH", packet[:6])
    if control != 0x11 or not 0 < length <= 4096 or len(packet) != length + 6:
        return None
    body = packet[6:]
    if b"DIAGADR" not in body:
        return None
    vin = re.search(rb"BMWVIN([A-HJ-NPR-Z0-9]{17})", body)
    return {"host": host, "vin": vin.group(1).decode("ascii") if vin else None,
            "identification_hex": packet.hex(" ").upper()}


def discover(bind_ip: str | None, trace: Trace, timeout: float = 2.5,
             destination: str = "255.255.255.255", port: int = DISCOVERY_PORT) -> list[dict]:
    if bind_ip:
        bind_ip = ipv4(bind_ip)
    found = {}
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.bind((bind_ip or "0.0.0.0", 0))
        packet = struct.pack(">IH", 0, 0x11)
        trace.add("Looking for a BMW ENET gateway...", bind_ip=bind_ip,
                  destination=destination, port=port, request_hex=packet.hex(" ").upper())
        sock.sendto(packet, (destination, port))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            sock.settimeout(max(0.001, deadline - time.monotonic()))
            try:
                response, sender = sock.recvfrom(8192)
            except socket.timeout:
                break
            identity = parse_identification(response, sender[0])
            trace.add("Received discovery response.", host=sender[0],
                      accepted=identity is not None, response_hex=response.hex(" ").upper())
            if identity:
                found[(identity["host"], identity["vin"])] = identity
    return list(found.values())


class EnetClient:
    def __init__(self, host: str, trace: Trace, bind_ip: str | None = None,
                 port: int = DIAGNOSTIC_PORT, timeout: float = 6.0):
        self.host = ipv4(host)
        self.trace, self.bind_ip, self.port, self.timeout = trace, bind_ip, port, timeout
        self.sock: socket.socket | None = None

    def __enter__(self):
        source = (ipv4(self.bind_ip), 0) if self.bind_ip else None
        self.sock = socket.create_connection((self.host, self.port), self.timeout, source_address=source)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.trace.add("TCP connection established; checking ECU responses next.",
                       host=self.host, port=self.port)
        return self

    def __exit__(self, *args):
        if self.sock:
            self.sock.close()
            self.sock = None

    def _exact(self, count: int, deadline: float) -> bytes:
        data = bytearray()
        assert self.sock is not None
        while len(data) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DiagnosticError("Timed out waiting for a complete ECU response.")
            self.sock.settimeout(remaining)
            try:
                part = self.sock.recv(count - len(data))
            except socket.timeout as exc:
                raise DiagnosticError("Timed out waiting for an ECU response. A gateway acknowledgement is not a code scan.") from exc
            if not part:
                raise DiagnosticError("Connection closed before a complete ECU response arrived.")
            data.extend(part)
        return bytes(data)

    def request(self, payload: bytes) -> bytes:
        if payload not in (VIN_REQUEST, DTC_REQUEST):
            raise ValueError("This prototype only permits VIN and fault-code read requests.")
        assert self.sock is not None
        frame = struct.pack(">IHBB", len(payload) + 2, 1, TESTER, DME) + payload
        self.trace.add("Sending read request.", direction="tx", frame_hex=frame.hex(" ").upper())
        self.sock.settimeout(self.timeout)
        self.sock.sendall(frame)
        deadline = time.monotonic() + self.timeout
        while True:
            header = self._exact(6, deadline)
            length, control = struct.unpack(">IH", header)
            if length > MAX_FRAME:
                raise DiagnosticError(f"Invalid ENET frame length: {length}.")
            body = self._exact(length, deadline)
            self.trace.add("Received ENET frame.", direction="rx", control=control,
                           frame_hex=(header + body).hex(" ").upper())
            if control >= 0x40:
                raise DiagnosticError(f"Gateway returned ENET error 0x{control:04X}.")
            if control != 1:
                # ACKs and unrelated control frames are not diagnostic results.
                continue
            if length < 3:
                raise DiagnosticError("Diagnostic frame is missing ECU addresses or data.")
            if body[0] != DME or body[1] != TESTER:
                self.trace.add("Ignored a response for a different ECU or tester.")
                continue
            response = body[2:]
            if response[0] == 0x7F:
                if len(response) != 3:
                    raise DiagnosticError("Malformed negative diagnostic response.")
                if response[1] != payload[0]:
                    continue
                if response[2] == 0x78:
                    # Keep waiting, with the original fixed overall deadline.
                    self.trace.add("ECU is still processing the read request.")
                    continue
                raise NegativeResponse(response[1], response[2])
            expected = bytes([payload[0] + 0x40]) + payload[1:3 if payload[0] == 0x22 else 2]
            if response.startswith(expected):
                return response
            self.trace.add("Ignored a diagnostic response that did not match this request.")


def parse_vin(response: bytes) -> str:
    if len(response) != 20 or response[:3] != b"\x62\xf1\x90":
        raise DiagnosticError("VIN response had an unexpected format.")
    try:
        vin = response[3:].decode("ascii")
    except UnicodeDecodeError as exc:
        raise DiagnosticError("VIN response was not ASCII.") from exc
    if not re.fullmatch(r"[A-HJ-NPR-Z0-9]{17}", vin):
        raise DiagnosticError("VIN response did not contain a valid 17-character VIN.")
    return vin


def parse_dtcs(response: bytes) -> tuple[int, list[dict]]:
    if len(response) < 3 or response[:2] != b"\x59\x02":
        raise DiagnosticError("Fault-code response had an unexpected format.")
    availability = response[2]
    records = response[3:]
    if len(records) % 4:
        raise DiagnosticError("Fault-code response contains an incomplete record.")
    if availability & 0x0C == 0:
        raise DiagnosticError("ECU does not advertise pending/confirmed status support; this scan cannot establish whether codes are present.")
    faults = []
    seen = set()
    for index in range(0, len(records), 4):
        record = records[index:index + 4]
        if record == b"\x00" * 4:  # Full zero-padding record.
            continue
        code = record[:3].hex().upper()
        status = record[3]
        if code == "000000" or status & availability & 0x0C == 0:
            raise DiagnosticError("ECU returned a fault record outside the requested status mask.")
        if code in seen:
            raise DiagnosticError("ECU returned duplicate fault records; preserve the raw response for review.")
        seen.add(code)
        faults.append({"code": code, "status_hex": f"{status:02X}",
                       "status_flags": [name for bit, name in enumerate(STATUS_NAMES)
                                        if status & availability & (1 << bit)]})
    return availability, faults


def scan(host: str | None = None, bind_ip: str | None = None,
         notify: Callable[[str], None] | None = None, *, port: int = DIAGNOSTIC_PORT,
         timeout: float = 6.0, discovery_destination: str = "255.255.255.255",
         discovery_port: int = DISCOVERY_PORT) -> dict:
    trace = Trace(notify)
    report = {"app": "Doc Otto Windows prototype", "version": "0.1.0",
              "target": "test vehicle, DME only",
              "hardware_validation": "Not yet validated on the MHD adapter / test vehicle",
              "started_utc": datetime.now(timezone.utc).isoformat(), "demo": False,
              "host": host, "bind_ip": bind_ip, "transport": "BMW ENET / HSFZ",
              "port": port, "ecu_address": f"{DME:02X}", "status_mask": "0C",
              "tcp_connected": False, "vin": None, "vin_status": "not_attempted",
              "dtc_status": "not_attempted", "faults": None,
              "status_availability_hex": None, "discovery": [], "errors": [],
              "trace": trace.events}
    try:
        if not math.isfinite(timeout) or not 0.1 <= timeout <= 30:
            raise ValueError("Timeout must be between 0.1 and 30 seconds.")
        if not 1 <= port <= 65535:
            raise ValueError("Invalid TCP port.")
        if bind_ip:
            bind_ip = ipv4(bind_ip)
        if not host:
            vehicles = discover(bind_ip, trace, destination=discovery_destination, port=discovery_port)
            report["discovery"] = vehicles
            if not vehicles:
                raise DiagnosticError("No BMW ENET gateway responded. Check the selected Wi-Fi interface and ignition. If broadcasts are blocked, enter the verified gateway/adapter IP manually.")
            if len(vehicles) != 1:
                raise DiagnosticError("Multiple vehicles responded. Enter the intended vehicle's IP manually.")
            host = vehicles[0]["host"]
        report["host"] = ipv4(host)
        with EnetClient(host, trace, bind_ip, port, timeout) as client:
            report["tcp_connected"] = True
            try:
                report["vin"] = parse_vin(client.request(VIN_REQUEST))
                report["vin_status"] = "success"
                trace.add("VIN read successfully.")
            except NegativeResponse as exc:
                # A complete ECU rejection keeps the stream synchronized.
                report["vin_status"] = "error"
                report["errors"].append(f"VIN: {exc}")
                trace.add(f"VIN unavailable: {exc} Continuing with the code read.")
            except (DiagnosticError, OSError) as exc:
                # A truncated/timed-out stream must not be reused for another request.
                report["vin_status"] = "error"
                report["errors"].append(f"VIN: {exc}")
                trace.add(f"VIN read failed: {exc} Reconnecting before the code read.")
                client.__exit__()
                client.__enter__()
            report["dtc_status"] = "in_progress"
            availability, faults = parse_dtcs(client.request(DTC_REQUEST))
            report["status_availability_hex"] = f"{availability:02X}"
            report["faults"] = faults
            report["dtc_status"] = "success"
            trace.add(f"Engine code read completed: {len(faults)} pending/confirmed code(s).")
    except (DiagnosticError, OSError, ValueError) as exc:
        report["dtc_status"] = "error"
        report["errors"].append(str(exc))
        trace.add(f"Scan failed: {exc}")
    report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    return report


def summary(report: dict) -> str:
    if report["dtc_status"] != "success":
        return "Scan failed — code status is unknown."
    count = len(report["faults"])
    if count == 0:
        return "No pending or confirmed engine codes were returned."
    return f"{count} pending/confirmed engine code(s) received."
