# Doc Otto — Windows code-reading experiment

An experimental local program for the **test vehicle** with an **MHD Universal Wi-Fi adapter operating in ENET mode**. It has a small desktop window and a command-line mode. Python 3.10 or newer is required; there are no pip dependencies.

**Status:** Software-tested with a simulated gateway. Not yet validated on the actual MHD adapter, Windows desktop, or test vehicle. A successful TCP connection alone does not establish that code reading works. This is a local experiment in `DocOtto/Prototypes/WindowsMhd`, separate from the mobile app and its generic OBD-II roadmap.

## Run on Windows

1. Extract the entire ZIP to a local folder. Keep `reader.py` and `doc_otto.py` together.
2. Install Python 3.10 or newer from <https://www.python.org/downloads/windows/> if needed. Include Tcl/Tk and the Python launcher. This is a Python program, not a prebuilt `.exe`.
3. With the vehicle parked and ignition on, plug in the MHD Universal adapter. Close MHD, BimmerLink, and other diagnostic apps so this test is the only diagnostic client.
4. Connect Windows Wi-Fi to the adapter's network using its password. Windows may report that this network has no internet; the test vehicle connection does not need internet access.
5. Double-click `start_windows.cmd`.
6. Select the **PC network interface connected to the adapter's Wi-Fi**. This matters if the PC also has an Ethernet or VPN connection. Click **Refresh interfaces** if the connection was made after opening the program.
7. Leave **Gateway / adapter IP** blank and click **Read engine codes**. If discovery fails, enter a verified ENET endpoint IP from the adapter's configuration or diagnostic capture. Do not assume that the Wi-Fi default gateway is necessarily the diagnostic endpoint.
8. Click **Save report** to save the result and raw diagnostic frames to a local JSON file. Failed scans can be saved too.

The program does not change network or firewall settings, install software, contact an online API, upload reports, or access Git. Reports can contain the VIN and local IP addresses.

## What it reads

- Vehicle discovery over UDP 6811 and BMW HSFZ diagnostic messages over TCP 6801.
- VIN from the engine ECU with UDS `22 F1 90`, when supported.
- Pending or confirmed engine fault records with UDS `19 02 0C`, using tester address `F4` and initial DME address `12`.
- Raw six-digit hexadecimal BMW codes and the ECU's status flags.

These address and protocol choices are initial assumptions to validate with the test vehicle and MHD adapter. This version does not implement the adapter's CAN mode or standardized DoIP on port 13400. It does not assume an ELM327 command interface.

The application sends no clear-code, session-change, ECU-reset, coding, flashing, security-access, or actuation requests. The two read requests above are explicitly allowlisted in the client.

## Interpreting the result

| Result | Meaning |
| --- | --- |
| Codes received | The engine ECU returned a complete, correctly addressed DTC response. Compare its six-digit codes with MHD. |
| No pending or confirmed engine codes returned | A valid DME response contained no records matching this status filter. This does not mean every module is fault-free. |
| Scan failed / status unknown | Communication, protocol, ECU addressing, or permissions prevented a trustworthy result. This is not a clean scan. |

VIN failure does not automatically invalidate a successful DTC read. A complete negative VIN response is logged and the code request proceeds. A truncated or timed-out VIN response triggers a fresh TCP connection before reading codes.

There are no fault descriptions, generic `Pxxxx` translations, freeze frames, live data, other-module scans, or code clearing in this experiment. BMW-specific codes are not automatically equivalent to generic OBD-II codes. MHD's broader scan may show additional categories; compare engine pending/confirmed records like for like.

## First test vehicle scan

1. Read codes using MHD and record the BMW engine codes and statuses it shows. Close the app afterward.
2. Run this reader, save its JSON report, and compare those results with the corresponding engine records from MHD.
3. Repeat twice to check that reconnection produces consistent results.
4. A valid empty response proves the read transaction works when there are no matching codes. Receiving an existing code and matching it with MHD additionally validates DTC parsing on the test vehicle. Do not deliberately create a vehicle fault for this test.

If it fails, preserve the report and identify the failing stage: discovery, TCP connection, VIN read, or DTC read. Useful follow-up evidence is the adapter's Wi-Fi mode, the selected interface IPv4 address, and the exact error. This build deliberately reports unsupported behavior rather than guessing another protocol or sending arbitrary requests.

## Troubleshooting

- **No interfaces listed:** Run `py -3 doc_otto.py --interfaces` in Command Prompt, or use `ipconfig` to find the PC Wi-Fi IPv4 address and pass it with `--bind` below.
- **No gateway discovered:** Confirm ignition is on, Windows is connected to the adapter, and the selected interface is correct. Windows Firewall or a VPN can block discovery. If Windows prompts, allow Python only on the network profile you intend to use; do not disable the firewall globally. The program does not require administrator access.
- **TCP connection fails:** The IP may not expose HSFZ on port 6801, or the adapter may be in a different mode. A browser-accessible configuration page is not proof of an accessible diagnostic endpoint.
- **TCP connects but ECU times out:** The DME address, adapter forwarding behavior, or transport assumptions may be wrong. Save the report; a gateway acknowledgement does not count as an ECU response.
- **Request rejected:** Save the exact negative response. This version does not automatically enter another diagnostic session or attempt security access.

## Command line

From the extracted folder in Command Prompt:

```bat
py -3 doc_otto.py --interfaces
py -3 doc_otto.py --cli --output scan.json
py -3 doc_otto.py --cli --bind PC_WIFI_IPV4 --host VERIFIED_ENET_IPV4 --output scan.json
```

Replace `PC_WIFI_IPV4` and `VERIFIED_ENET_IPV4` with actual numeric IPv4 addresses. Omit `--host` to use discovery. `--timeout` sets the fixed per-request deadline (default six seconds). Exit codes: `0` successful DTC read, `1` scan failure, `2` report-save or startup failure.

## Local software checks

```bat
py -3 -m unittest discover -s tests -v
```

Tests use synthetic vehicle data and local loopback sockets. They cover discovery plus a full scan, fragmented and combined TCP frames, gateway acknowledgements, response-pending messages, rejected requests, wrong ECU addresses, truncated replies, empty results, request restrictions, reconnect behavior, and report saving. They do not establish Windows UI or actual adapter compatibility.

## Protocol references

Original implementation using Python's standard library; no third-party library code or BMW diagnostic databases are bundled.

- MHD adapter capabilities: <https://mhdtuning.com/pages/mhd-wireless-adapter>
- Scapy's HSFZ protocol implementation: <https://github.com/secdev/scapy/blob/master/scapy/contrib/automotive/bmw/hsfz.py>
- UDS ReadDTCInformation documentation: <https://udsoncan.readthedocs.io/en/latest/udsoncan/services.html#readdtcinformation-0x19>
- ENET Wi-Fi on Windows: <https://uholeschak.github.io/ediabaslib/docs/ENET_WiFi_Adapter.html>
