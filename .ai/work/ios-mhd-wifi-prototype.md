# Native iOS MHD Wi-Fi prototype

Status: Prototype implemented; prior test-device installation completed, physical launch and MHD validation pending
Started: 2026-10-27

## Intent

Build the first runnable native iOS prototype in the repository. Connect through
an MHD Universal Wi-Fi adapter in ENET mode, using the existing Windows
experiment's VIN and raw pending/confirmed engine-code path.

## Scope and constraints

- Keep implementation changes local for this task; do not commit, push, open a PR or issue, or publish without a separate request.
- Preserve existing Windows, BLE, and Android work and the generic OBD-II roadmap.
- SwiftUI app plus reusable ENET/HSFZ transport using Network.framework.
- Explicit verified gateway IPv4, TCP 6801, tester F4, DME 12.
- Only VIN 22 F1 90 and engine DTC 19 02 0C requests are allowed.
- Raw six-digit codes and supported status flags; no inferred code definitions.
- Manual Wi-Fi joining and unicast connection. Broadcast discovery requires an
  additional Apple entitlement on a physical iPhone and is outside this milestone.
- Explicit demo mode; no synthetic data in an actual scan result.
- Failure/cancellation leaves code status unknown, distinct from a valid empty read.
- Local JSON/raw-frame report sharing on user action.

## Workflow

Read `AGENTS.md` and project context before editing. The `ai` workflow CLI is
optional; run the checks in `.ai/validate.toml` directly where it is unavailable.
Coordinate pulls with other contributors and preserve local working-tree changes.

## Delivered

- SwiftUI iPhone app and shared Xcode scheme with a local diagnostic package dependency.
- Native Network.framework Wi-Fi TCP stream, incremental HSFZ framing and ENET
  transport with validated endpoints, fixed deadlines and bounded wire traces.
- Connection settings, VIN/raw engine-code results, pinned scan/cancel controls,
  typed progress, explicit demo, logs and JSON share sheet.
- Fresh sessions, cancellation/background cleanup and run-token protection against
  stale callbacks. Changing a saved endpoint clears the preceding result.
- Setup/implementation instructions and durable architecture/decision updates.

## Validation

- Shared Swift package: 45 tests passed (31 existing and 14 ENET tests), including
  an actual Network.framework TCP loopback VIN/code scan.
- iOS app model: 9 XCTest tests passed in an available iOS simulator.
- Simulator Debug build: passed.
- Physical iOS SDK Debug build without code signing: passed.
- A signed Debug build and test-device installation previously succeeded using a
  developer-specific provisioning profile. First launch was blocked by an iOS
  developer-certificate trust message; this does not establish runtime compatibility.
  Each developer must configure their own signing credentials and device trust.
- Simulator app launched with clearly marked demo results; layout visually inspected.
- Existing Windows reader: 18 tests passed.
- Git whitespace and required project context checks: passed.
- Android validation was not run during that earlier iOS task due to a missing
  Java runtime in the test environment. Run Android tests where JDK 17 is available;
  no Android source changes were made in that task.
- Existing CoreBluetooth delegate-isolation compiler warnings remain in the
  unchanged BLE code. The new Wi-Fi sources build in the project's Swift 5 mode.

## Handoff

Open `DocOtto/App/iOS/DocOtto.xcodeproj` on a Mac with Xcode installed. Select
your own development team and target iPhone in Xcode, then sign, install, and
verify launch. If iOS requires developer trust, follow Settings > General >
VPN & Device Management on the test device.
Use MHD Universal ENET Wi-Fi
and the verified diagnostic host from a successful Windows scan report. Allow
Local Network access and compare like-for-like engine pending/confirmed results.
The prototype does not need internet access or a multicast entitlement.

No physical MHD/vehicle connection was attempted; no code was committed, pushed,
published or submitted as a PR. Physical hardware validation is the next step.
