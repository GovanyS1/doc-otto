# Doc Otto — native iOS MHD Wi-Fi prototype

A runnable SwiftUI app for the **MHD Universal adapter in ENET mode** and the
**test vehicle**, using the same raw engine-read path as the Windows experiment.
Open `DocOtto.xcodeproj` in Xcode. The minimum deployment target is **iOS 16**.

The app reads the VIN and pending/confirmed engine fault records, shows raw
six-digit hexadecimal codes and status flags, and can share a local JSON report.
A clearly marked demo lets you explore the interface without an adapter.
The bottom navigation has four tabs: **Scan**, **Live**, **History**, and
**Settings**. Scan contains the existing working prototype; the other tabs are
clearly labeled placeholders. The system tab bar uses native Liquid Glass on
iOS 26+ and the standard tab bar on earlier supported iOS versions.

The supplied duck-and-wrench artwork is the app icon and the small logo in the
home screen header. Its App Store icon export has a white opaque background and
is built into the Xcode asset catalog, with no additional image dependencies.

**Hardware status:** iPhone/MHD/test-vehicle communication has not yet been
validated for this iOS implementation. Initial Windows hardware test reports are the
basis for the transport choice, not proof of iPhone compatibility. Simulator and
loopback results are software evidence only.

## Open and run

On macOS with Xcode installed, from the repository root:

```bash
open DocOtto/App/iOS/DocOtto.xcodeproj
```

1. Select the **DocOtto** scheme.
2. Choose an installed iPhone simulator and press **Run**.
3. Tap **Explore with sample data** to see the demo, or open **Connection**
   to configure a real endpoint. The normal launch has no host or results.
4. The demo banner, sample VIN label, and report source identify synthetic data.
   Tap **Exit demo** to return to the initial screen.

The project uses the sibling `../Diagnostics` local Swift package. Keep the
repository directory structure intact; no third-party package download is needed.

For a physical iPhone, select the **DocOtto** app target, choose your development
team under **Signing & Capabilities**, connect/select the iPhone, and run from
Xcode. Follow Xcode's device trust and Developer Mode prompts if required.
Xcode manages development signing and provisioning locally. After installation,
if iOS has not trusted the signing developer, open **Settings > General > VPN &
Device Management** on the iPhone and trust the developer certificate for the
Apple Account used to sign this app, then launch Doc Otto again. This is separate
from Developer Mode and the computer-pairing trust prompt.

## Connect to the MHD adapter

1. Park the vehicle and switch the ignition on.
2. Plug in the MHD Universal adapter and select its **ENET** mode/network.
   This prototype does not implement the adapter's CAN mode.
3. Close MHD and other diagnostic apps using the adapter.
4. In the iPhone's Wi-Fi Settings, join the adapter network with its configured
   password. This network does not need internet access.
5. In Doc Otto, open **Connection**, choose **Wi-Fi** and **BMW MHD ENET (legacy)**,
   and leave **Find BMW gateway automatically** enabled. Save without entering an IP.
   Alternatively turn this off and enter the **verified diagnostic gateway IPv4 address**.
6. Tap **Connect & read codes** and allow **Local Network** access when prompted.
   Keep Doc Otto in the foreground until it completes.
7. Inspect the VIN, raw codes, and status labels. Use **Scan log** or **Share report**
   to preserve diagnostic evidence, including failed scans.

### Automatic discovery and the Apple entitlement

Auto mode sends the six-byte HSFZ identification request `00 00 00 00 00 11`
to UDP broadcast port **6811** on the iPhone's Wi-Fi interface, waits up to
2.5 seconds for replies, validates the BMW identification frame, and opens
TCP **6801** at the responding gateway's actual IPv4 source address. It never
guesses the router address or scans IP ranges. If more than one gateway replies,
the scan stops instead of selecting an arbitrary car. Discovery is initiated
only after the user taps **Connect & read codes**. It can be cancelled, and does
not transmit any vehicle control or write commands.

**Physical iOS restriction:** Apple requires the restricted
`com.apple.developer.networking.multicast` entitlement to send UDP broadcasts
on an iPhone. A local-network permission string alone is not sufficient. Once
Apple approves the capability for the development team, enable **Multicast
Networking** in the app target's **Signing & Capabilities** and use an updated
provisioning profile that contains it. Until that approval, automatic discovery
is implemented but may be blocked on the physical device. The Xcode project
intentionally does **not** add an unapproved entitlement because doing so could
break signing and the existing manual scanner. The app reports this limitation
and lets users switch to **Manual IP**. Simulator or macOS discovery tests do
not verify on-device entitlement or MHD firmware behavior.

Apple entitlement documentation:
<https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast>

### Where to get the manual IP address

Use the `host` field in a JSON report from a successful run of the existing
Windows MHD reader, or another independently verified diagnostic capture.
The Wi-Fi router/configuration-page address is not necessarily the diagnostic
endpoint. No adapter IP is guessed or bundled.

The field accepts numeric private or link-local IPv4 addresses. TCP port **6801**,
tester **F4**, and engine ECU **12** match the Windows prototype. Loopback is
available only in the simulator/macOS for local tests; physical iOS requires Wi-Fi.

The read connection uses unicast TCP. The optional discovery phase uses Wi-Fi
UDP broadcast, with the Apple entitlement restriction described above. The app
does not request Bonjour, Hotspot Configuration, or location access for this
flow. Its Info.plist includes `NSLocalNetworkUsageDescription`.

## What a result means

| Result | Meaning |
| --- | --- |
| Engine codes returned | A complete matching engine ECU response was received and parsed. |
| Zero codes | The ECU successfully returned no records for the supported requested statuses. Other modules were not scanned. |
| Failed or cancelled | Code status is unknown. The UI clears previous results and the report uses `faults: null`. |
| Demo | Synthetic results from an in-process simulated transport; no network connection. |

The request filter is pending **or** confirmed (`0C`). If the ECU advertises
only one of those status bits, the app shows the missing category as unknown.
It never labels unavailable status support as absence of faults.

These are raw three-byte UDS engine codes. They are not automatically generic
OBD-II `Pxxxx` codes. No definitions, repair diagnoses, full-module scan, live
data, code clearing, coding, programming, session changes, ECU resets, security
access, or arbitrary request entry is provided.

A completed scan closes the connection. **Scan complete** is a result from that
time, not a persistent connected state. Each new scan creates a fresh connection.
A complete ECU rejection of VIN can still allow the code read. A timed-out,
truncated, or malformed VIN response ends this scan; retry starts a fresh session.

## Local reports

**Share report** creates `DocOtto-Scan.json` in the app's temporary report folder
and opens the standard iOS share sheet. It works for completed, failed, cancelled,
and demo scans. There is no automatic upload, account, API key, or paid service.

The report includes:

- Source (vehicle/demo), immutable scanned endpoint, start/end timestamps and outcome.
- VIN when available, raw fault codes, raw/supported status flags and requested/
  evaluated/unavailable status masks.
- Errors and available diagnostic frames.
- Explicit physical-device validation status.

Trace storage is bounded to the latest 128 events. Each wire frame is capped at
512 bytes in the trace and visibly marked if truncated. The full received payload
is still parsed, within the framing size limit. Reports may contain a VIN and
local network details; sharing is an explicit user action. There is no saved scan
history in this prototype. Only the configured endpoint is retained in preferences.

## Implementation

| Location | Responsibility |
| --- | --- |
| `DocOtto/DocOttoApp.swift` | App entry and foreground lifecycle |
| `DocOtto/ContentView.swift` | Connection setup, scan states, codes, log and share sheet |
| `DocOtto/ScanViewModel.swift` | Scan ownership, typed progress, demo, cancellation and reports |
| `../Diagnostics/.../HSFZ.swift` | Endpoint validation and incremental TCP framing |
| `../Diagnostics/.../NetworkTCPByteStream.swift` | Native Network.framework connection |
| `../Diagnostics/.../ENETTransport.swift` | Serialized allowlisted reads and bounded trace |
| `../Diagnostics/.../Diagnostics.swift` | Existing shared UDS validation, parsing and orchestration |

Connections and requests have fixed deadlines. Pending ECU responses do not reset
the request deadline. A gateway ACK is not a successful read. Partial frames,
wrong addresses, duplicates, negative responses, disconnects and cancellation are
handled explicitly. Starting a new run invalidates callbacks from an old run.
Saving a different configured host clears the prior on-screen result.

Going to the background cancels a scan. Merely becoming inactive, such as while
the Local Network permission alert is visible, does not cancel it.

## Verification

Run the shared diagnostic tests from the repository root:

```bash
swift test --package-path DocOtto/App/Diagnostics
```

Run the app's state/report tests with **Product → Test** in Xcode, or:

```bash
xcodebuild -project DocOtto/App/iOS/DocOtto.xcodeproj \
  -scheme DocOtto \
  -destination 'platform=iOS Simulator,id=<installed-simulator-UDID>' \
  -derivedDataPath DocOtto/App/iOS/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

Replace `<installed-simulator-UDID>` with an identifier from `xcrun simctl list devices available`. The test scheme
runs the application state tests; the Swift package command runs the protocol
and transport tests, including a real TCP loopback simulated gateway on macOS.

Build the device SDK without provisioning:

```bash
xcodebuild -project DocOtto/App/iOS/DocOtto.xcodeproj \
  -scheme DocOtto -destination 'generic/platform=iOS' \
  -derivedDataPath DocOtto/App/iOS/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

An unsigned device build proves compilation; it cannot be installed on an iPhone
until Xcode signs it with your development team.

## First physical test

Use the same MHD ENET setup and endpoint that worked with the Windows reader.
Compare returned engine pending/confirmed codes and statuses with MHD, then close
MHD before running Doc Otto. Save a report, repeat the scan, and check reconnection.
A valid empty result verifies the read transaction but does not validate parsing
of a real nonempty fault list. Do not deliberately create a vehicle fault.

If a scan fails, share its report and note the adapter's model, firmware, mode,
and verified endpoint. Check **Settings → Privacy & Security → Local Network**
if permission was denied. A successful TCP connection by itself does not verify
ECU addressing or code reads.

## References

- [MHD Universal capabilities](https://mhdtuning.com/pages/mhd-wireless-adapter)
- [Apple local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple networking APIs and broadcast requirements](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)
- [Scapy HSFZ wire-format reference](https://github.com/secdev/scapy/blob/master/scapy/contrib/automotive/bmw/hsfz.py)

The Swift framing implementation is original; no Scapy source or proprietary
diagnostic database is bundled.

## Universal OBD-II update (local, uncommitted)

Connection now offers **Wi-Fi** or **Bluetooth LE**, with generic SAE J1979 / ELM327 as the Wi-Fi default. The Wi-Fi TCP host/port is configured manually (the often-used port 35000 is only a starting value; use your adapter's documentation). BLE discovery lists nearby devices and allows UART profiles FFE0/FFE1, Nordic UART, or user-entered GATT UUIDs. Detection alone does not establish compatibility. iOS cannot connect to ordinary Bluetooth Classic SPP ELM327 hardware through Core Bluetooth.

Standard generic scans send adapter configuration (`ATZ`, `ATE0`, `ATL0`, `ATS0`, `ATH0`, `ATSP0`), OBD protocol probe `0100`, optional VIN `0902`, stored DTC `03`, pending DTC `07`, and permanent DTC `0A`. Results distinguish unavailable optional services from successful empty replies. They are emissions-related ECU reads, not complete-system scans, manufacturer-specific descriptions, ABS/airbag scans, code clearing or service resets. A no-data stored-code response is treated as an inconclusive scan rather than 'no faults'. All requests are read-only.

**BMW MHD ENET (legacy)** remains a separate Wi-Fi protocol option with either automatic HSFZ gateway discovery (UDP 6811, subject to Apple's restricted entitlement) or a verified manual IP setup (TCP 6801, VIN `22 F1 90`, DTC `19 02 0C`). It does not use universal OBD-II requests, and raw BMW UDS codes are kept distinct from standardized OBD DTCs. **Do not assume MHD ENET firmware accepts ELM327 command strings**: select the BMW option for the existing MHD experiment until another documented MHD mode is verified.

The simulator can exercise the synthetic generic scan. BLE device scanning and real ELM327 Wi-Fi/BLE compatibility require testing with actual hardware on a physical iPhone. The app never automatically selects arbitrary nearby devices or guesses LAN addresses. Local settings preserve the user's choice; no remote server or subscription is required.
