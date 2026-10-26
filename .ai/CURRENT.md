# Current Work

Doc Otto now has initial UI-independent diagnostic logic in Swift at `DocOtto/App/Diagnostics` and Android/Java at `DocOtto/App/AndroidDiagnostics`, assuming a configurable BLE/ELM327 CAN adapter. No actual BLE adapter/GATT profile or test-vehicle CAN route has been validated. The Android bridge compiles against API 35; Apple SDK compilation, full Android packaging, and physical phone tests remain pending. The separate Windows/MHD experiment has user-reported successful VIN and raw engine-code reads on the test vehicle; broader compatibility remains unverified.

## Completed

- Created the repository workflow guide.
- Added durable `.ai/` product, architecture, and current-work context.
- Added deterministic baseline validation.
- Defined Doc Otto at a high level as an iOS app that connects to a vehicle's OBD scanner over Wi-Fi and reads fault codes.
- Defined the initial user flow as connecting to the scanner, scanning the vehicle, and viewing diagnostic trouble codes.
- Recorded provisional architecture boundaries for network transport, OBD communication, code parsing, and UI.
- Defined a committed 30-feature product roadmap covering tested Wi-Fi and BLE adapters, generic DTCs, live data, vehicle history, maintenance, reporting, accessibility, and other supporting capabilities.
- Limited diagnostic scope to standardized, generic emissions-related OBD-II features; manufacturer-specific definitions and enhanced-module diagnostics are not promised.
- Established a low-recurring-cost data strategy centered on bundled content, on-device behavior, NHTSA public resources, and optional Supabase services.
- Prepared a local Windows desktop/CLI prototype with ENET gateway discovery, VIN reading, pending/confirmed DME fault reading, status parsing, and local JSON/raw-frame export.
- Passed 18 simulated-gateway tests covering successful reads and communication failures. This is software evidence, not an actual Windows/MHD/test vehicle compatibility result.
- Kept this experiment separate from the generic OBD-II mobile roadmap; no fault definitions or generic-code translations are inferred.
- Added the native Swift diagnostic package: configurable BLE byte stream, prompt framing, ELM327 CAN setup, ISO-TP assembly, raw UDS VIN/fault parsing, and scan orchestration.
- Passed 31 simulated Swift tests on Linux, including a complete mocked BLE/ELM/CAN/UDS scan, malformed replies, timeouts, concurrency, cancellation, and valid empty results. Apple Core Bluetooth is excluded from the Linux build.
- Kept the native packages free of UI and app-shell code as requested. The user subsequently authorized committing, pushing, and opening a PR for the completed diagnostic logic.
- Added a Java Android counterpart with the same UDS requests, ELM/CAN transport, ISO-TP assembly, fault/VIN parsing, and a native Android BLE byte stream.
- Passed 35 Android JVM tests and compiled the BLE Java source against Google's AOSP API 35 reference jar with warnings treated as errors. These are not real Android/radio/vehicle tests.

## Next

The next native milestone is selecting the BLE adapter and its documented GATT behavior, verifying the physical engine-ECU CAN route/bit rate, compiling with an Apple SDK, validating Android Gradle/AAR packaging and host-app permissions, and testing the read-only flow on physical phones. Do not treat fixture addresses as working BMW configuration. The user authorized committing and pushing the prepared native work and opening a PR titled `diagnostics logic for IOS and android` with the supplied three-bullet description. No tracking issue or merge is requested.

Windows experiment follow-up:

- Run `DocOtto/Prototypes/WindowsMhd/start_windows.cmd` on Windows with Python 3.10+ and Tcl/Tk installed.
- Connect Windows to the MHD adapter's ENET Wi-Fi network, select that PC interface, and read the engine codes.
- Save the scan report, compare like-for-like engine pending/confirmed records with MHD, and check repeatability.
- Record the actual adapter firmware/mode and working network endpoint once established. Treat discovery/ECU/transport failures as unknown code status.
- A valid empty reply proves a successful read transaction; matching an existing code with MHD also validates record parsing on the test vehicle. Do not deliberately induce faults for the test.

Before production mobile integration:

- Identify the first supported Wi-Fi OBD scanner or scanner family.
- Identify the first supported BLE OBD scanner or scanner family.
- Confirm the scanner's network protocol and command behavior.
- Decide the minimum supported vehicle/OBD-II compatibility target.
- Select a licensed or otherwise distributable source for offline generic DTC definitions.
- Define the review process for common-cause and guided-checklist content.
- Divide the committed product roadmap into release milestones.
- Define the first mobile implementation milestone using the desktop experiment's findings.

## Needs Review

- Supported OBD scanner/protocol scope.
- Host-app integration and compilation of the Core Bluetooth transport with an Apple SDK.
- Android host-app integration, Gradle/AAR packaging, manifest/runtime permissions, and physical GATT callback behavior.
- Saved-report comparison and repeatability beyond the user-reported Windows VIN/code reads; the working MHD adapter endpoint and firmware/mode still need recording.
- Mobile implementation milestone; a BMW-specific raw read does not establish generic OBD-II or cross-brand support.
- Roadmap release sequencing.
- Diagnostic-content sourcing, licensing, and review.
