# Architecture

Doc Otto has an iOS vehicle-diagnostics product roadmap, reusable diagnostic libraries in Swift and Android/Java, and a runnable SwiftUI MHD Wi-Fi prototype. The product roadmap includes both Wi-Fi and BLE scanner transports. MHD Universal in ENET mode is the current iOS prototype target; production-supported compatibility still requires physical validation.

## Current Direction

The first architecture should support a simple diagnostic path:

1. The iPhone joins or reaches a tested OBD scanner over the supported Wi-Fi or BLE transport.
2. Doc Otto opens the appropriate connection to the scanner.
3. The app communicates with the vehicle through the scanner using the appropriate OBD protocol/command layer.
4. The app requests diagnostic trouble codes (DTCs).
5. Returned fault codes are parsed into a stable internal representation.
6. The UI presents the detected codes clearly to the user.

Keep scanner communication, transport, code parsing, diagnostic content, persistence, and UI separate so roadmap features can be added without tightly coupling the app to one screen, one adapter implementation, or one external data source.

## Boundaries To Preserve

- iOS UI and application state.
- Wi-Fi and BLE transport to tested OBD scanners.
- OBD command/protocol handling.
- Diagnostic trouble code parsing and representation.
- Bundled generic-code descriptions and curated diagnostic-checklist content.
- Vehicle, scan, sensor, maintenance, and repair-history persistence.
- Report generation and normal iOS sharing.
- Optional NHTSA and Supabase integrations behind explicit service boundaries.

The native Swift package includes Apple Network.framework ENET Wi-Fi and Core Bluetooth transports. The iOS prototype persists only the manually configured endpoint and exports reports on user action. No production-supported OBD adapter, vehicle CAN route, full persistence layer, or distributable generic-DTC dataset has been selected yet.

## Local Windows Feasibility Experiment

`DocOtto/Prototypes/WindowsMhd` is a separate Python 3.10+ experiment for the MHD Universal adapter and test vehicle. It is not the mobile implementation or a change to the generic diagnostic product promise.

- `reader.py` separates local interface enumeration, UDP ENET discovery, framed TCP HSFZ transport, UDS read requests, parsing, and a structured report.
- `doc_otto.py` supplies a Tk desktop window and CLI. Network work runs outside the UI thread.
- The only diagnostic requests allowed are VIN `22 F1 90` and pending/confirmed DTCs `19 02 0C`, initially addressed from tester `F4` to DME `12` on TCP 6801. These assumptions require hardware validation.
- No arbitrary commands, clearing, session changes, resets, coding, flashing, or security access are exposed.
- Failure retains `faults: null`; only a valid successful response may produce an empty list. Gateway acknowledgements alone do not count as code reads.
- Reports and raw frames are saved locally only on user action (or an explicit CLI output path). There are no online dependencies, proprietary diagnostic databases, inferred definitions, or automatic uploads.
- Initial Windows hardware testing reportedly returned VIN and raw code numbers with an MHD adapter and test vehicle. Saved-report comparison and broader compatibility remain unverified; simulated tests establish software behavior only.

## Native iOS MHD Wi-Fi Prototype

`DocOtto/App/iOS/DocOtto.xcodeproj` builds a SwiftUI iPhone app targeting iOS 16+. It depends on the sibling diagnostic package by local path.

- Connection setup uses a verified private/link-local IPv4 endpoint, TCP 6801, tester F4 and DME 12; the physical iOS TCP path requires Wi-Fi.
- Only existing VIN `22 F1 90` and pending/confirmed fault `19 02 0C` requests are exposed. It preserves raw three-byte codes and does not claim generic P-code support.
- `HSFZDecoder` handles partial and combined TCP frames. `ENETTransport` excludes gateway ACKs from results, matches addresses/services, enforces fixed deadlines, bounds traces, and invalidates malformed or cancelled sessions.
- `ScanViewModel` owns each fresh scan, freezes its endpoint, rejects overlapping starts, clears stale results, and prevents cancelled callbacks from updating later runs.
- Backgrounding cancels the scan; becoming inactive for an iOS permission prompt does not. The Info.plist supplies Local Network permission text.
- Manual Wi-Fi joining and unicast TCP avoid requiring Apple's restricted multicast/broadcast entitlement. Discovery is deferred.
- UI includes connection setup, typed progress, raw codes/statuses, explicit synthetic demo, log and local JSON share sheet. Changing a saved host clears previous results.
- Only the host is persisted in preferences. Reports are created on user action and include source, endpoint, timestamps, status masks, errors and available wire frames. Failed/cancelled results encode faults as null.
- Shared-core tests include a native TCP loopback gateway; app tests cover state, cancellation and export. Software tests do not establish physical iPhone/MHD compatibility.
- The generic OBD-II roadmap, existing BLE library, Android library and Windows prototype remain separate from this narrowly scoped raw-engine experiment.

## Native Bluetooth Diagnostic Logic

`DocOtto/App/Diagnostics` is a Swift package with no UI or app executable. It is an enhanced raw-UDS experiment and reusable foundation, separate from the generic OBD-II product promise.

- DMEReader creates a fresh transport for each scan and reads VIN followed by pending/confirmed raw UDS faults.
- CoreBluetoothByteStream connects only to an explicitly selected BLE peripheral using configured GATT UUIDs and write mode. The future host app must provide Bluetooth permission text and peripheral selection.
- PromptCommandChannel owns ASCII prompt framing, serialized commands, bounded replies, deadlines, cancellation, and a bounded in-memory trace.
- ELM327Transport uses explicit physical 11-bit CAN request/response IDs and bit rate, raw CAN formatting, receive filtering, and adapter-managed ISO-TP flow control. No actual adapter/vehicle profile is bundled.
- ISOTPAssembler and UDS parsers reject incomplete, mismatched, duplicate, and unsupported replies. Read failures throw instead of producing an empty fault list; supported/unsupported status masks remain explicit.
- Only VIN and pending/confirmed fault reads are exposed. A complete VIN rejection allows the code read; an incomplete VIN transaction stops the scan. Timeout/cancellation invalidates the session.
- Linux tests use simulated streams. Apple SDK compilation is now exercised by the iOS app in Swift 5 mode; existing delegate-isolation warnings remain in the BLE implementation. Actual iPhone/BLE-adapter/vehicle behavior is unverified.
- The BLE package path includes no UI, web server, manufacturer descriptions, permanent-code reads, generic OBD-II service 03, clearing, ECU discovery, coding, programming, or authentication bypass. The separate iOS app currently integrates ENET Wi-Fi only.

## Android Diagnostic Counterpart

`DocOtto/App/AndroidDiagnostics` mirrors the Swift protocol layers in Java, with a portable core and an Android BLE library targeting API 26+. Android BLE source compiles against API 35.

- DmeRequest restricts vehicle requests to VIN and pending/confirmed UDS faults. DmeReader creates/closes a transport per scan and exposes an interruptible blocking scan for caller-owned workers.
- PromptCommandChannel frames ELM ASCII replies, serializes operations, uses monotonic deadlines, rejects ambiguous streams, and retains a bounded in-memory trace.
- AndroidBleByteStream connects only to the caller-selected BluetoothDevice, validates configured GATT properties, writes CCCD notifications/indications, and waits for GATT write callbacks. API 33 overloads carry values directly; older supported Android versions use their legacy overloads.
- No selected device, GATT profile, or DME CAN route is bundled. Runtime connection permission and future device selection belong to the host app. Blocking I/O is rejected on the main thread.
- Notification data is bounded; disconnect, timeout, and interruption unblock waits and release the GATT connection and callback thread.
- The core uses the same ISO-TP/UDS parser constraints and explicit status-availability masks as Swift. Successful empty reads remain distinct from failures.
- 35 simulated JVM tests and API 35 source compilation provide software evidence. Full Gradle/AAR packaging, host-app permissions/manifest integration, real callback behavior, and phone/adapter/vehicle tests remain pending.
- This adds an Android diagnostic foundation without defining a full Android product roadmap or altering the existing Swift/Windows sources.

## Engineering Principles

- Keep vehicle communication behavior explicit and testable.
- Avoid coupling the app to one scanner model unless that is an intentional product decision.
- Treat commands that can alter vehicle state differently from read-only diagnostic operations.
- Require an explicit user confirmation before generic DTC clearing and warn that clearing may erase freeze-frame data and reset readiness monitors.
- Keep unsupported manufacturer-specific codes distinct from verified generic definitions.
- Keep recurring external-service dependencies minimal and replaceable.
- Keep secrets, API keys, and credentials outside the repository.
- Prefer deterministic validation and reproducible local workflows.
- Record durable architecture decisions in `.ai/decisions/`.
