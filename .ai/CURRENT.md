# Current Work

Doc Otto has a runnable native SwiftUI iOS prototype at `DocOtto/App/iOS/DocOtto.xcodeproj`, connecting through MHD Universal Wi-Fi in ENET mode. It reuses the Swift diagnostic package with a Network.framework/HSFZ transport. Earlier validation passed simulator and unsigned device SDK builds, 45 shared-core tests, 9 iOS app-state/report tests, and 18 Windows tests. A prior signed development build was installed on a test iPhone, but first launch was blocked by developer-certificate trust settings. Each developer must configure their own signing team and device trust. Physical iPhone/MHD/test-vehicle communication remains unverified. Prototype work may still be uncommitted in local checkouts.

The original BLE/ELM327 Swift and Android/Java libraries remain separate transport experiments without a verified BLE adapter/GATT profile or vehicle CAN route. The Android bridge was previously compiled against API 35; full Android packaging and physical-phone tests remain pending. The Windows/MHD experiment has user-reported successful VIN and raw engine-code reads on the test vehicle.

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
- Added a native SwiftUI iOS app with connection setup, VIN/raw engine-code results, cancellation, explicit demo, log and local JSON report sharing.
- Added ENET/HSFZ framing and a native TCP transport with explicit private/link-local IPv4 configuration, TCP 6801, tester F4, DME 12, fixed deadlines and physical iOS Wi-Fi routing.
- Reused the existing allowlisted VIN and pending/confirmed engine reads; no generic P-code translations or code-clearing operations were added.
- Added 14 shared-core ENET tests including a complete native TCP loopback scan; all 45 Swift tests passed in an earlier macOS validation run.
- Added 9 iOS model tests covering empty versus unknown outcomes, frozen endpoints, cancellation, stale callbacks, mode changes and report data; all passed in the iPhone simulator.
- Built for both the simulator and physical iOS SDK without provisioning changes, and visually inspected the simulator interface.
- Documented the verified manual gateway-IP requirement and physical-device setup in `DocOtto/App/iOS/README.md`.
- Completed an earlier development-signed build and test-device installation. Each developer must select their own signing team and test device in Xcode; first-launch trust and physical adapter communication still need verification.

## Next

For physical iOS validation, select a development team and test device in Xcode, install and launch the app, then complete any developer trust or Developer Mode steps required on that device. Join the MHD ENET Wi-Fi network, use a verified diagnostic host from a successful capture, grant Local Network access, and compare engine pending/confirmed results with MHD. Save the JSON report and verify reconnection. No successful physical iOS adapter scan has yet been documented.

Development tasks must follow their own delivery instructions; do not infer permission to commit, push, open issues, or merge from old handoffs. The `ai` workflow CLI is optional; when unavailable, run checks from `.ai/validate.toml` directly. Android tests need JDK 17 or the documented Docker fallback, while bridge compilation additionally requires an API 35 SDK jar. Record missing-tool limitations for the current environment rather than treating them as project-wide blockers.

Future BLE work still needs a documented adapter/GATT profile and verified physical CAN route. Android packaging and phone permissions remain pending. Do not treat fixture endpoints or CAN identifiers as working vehicle configuration.

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
- Physical iPhone launch with each developer's signing configuration, MHD communication, verified gateway IP, and saved-report comparison.
- Runtime Core Bluetooth behavior; Apple SDK compilation succeeds in Swift 5 mode with pre-existing delegate-isolation warnings that require attention before Swift 6 language mode.
- Android host-app integration, Gradle/AAR packaging, manifest/runtime permissions, and physical GATT callback behavior.
- Saved-report comparison and repeatability beyond the user-reported Windows VIN/code reads; the working MHD adapter endpoint and firmware/mode still need recording.
- The native Wi-Fi prototype is a raw-engine experiment; it does not establish generic OBD-II or cross-brand support.
- Roadmap release sequencing.
- Diagnostic-content sourcing, licensing, and review.

## 2026-10-30 local iOS generic-scanner work

Implemented a new generic SAE J1979 / ELM327 read-only scan layer (automatic adapter protocol selection, probe, optional VIN, stored/pending/permanent codes) and separate persisted Wi-Fi TCP / discovered BLE GATT choices in the native iOS project. Kept BMW ENET as the separate advanced Wi-Fi selection. UI displays standard DTCs with status categories, with appropriate Local Network and Bluetooth permission descriptions. Added simulator-safe demo and generic protocol tests. Physical scanner/vehicle validation remains pending; no commit or push requested.
