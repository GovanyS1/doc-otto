# Architecture

Doc Otto is an iOS vehicle-diagnostics application. Mobile implementation has not started, so most technical choices remain intentionally undecided. The product roadmap includes both Wi-Fi and BLE scanner transports, although the first supported adapter and transport remain to be selected.

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

No specific OBD adapter, command set, transport library, persistence layer, or distributable generic-DTC dataset has been selected yet.

## Local Windows Feasibility Experiment

`DocOtto/Prototypes/WindowsMhd` is a separate Python 3.10+ experiment for the MHD Universal adapter and test vehicle. It is not the mobile implementation or a change to the generic diagnostic product promise.

- `reader.py` separates local interface enumeration, UDP ENET discovery, framed TCP HSFZ transport, UDS read requests, parsing, and a structured report.
- `doc_otto.py` supplies a Tk desktop window and CLI. Network work runs outside the UI thread.
- The only diagnostic requests allowed are VIN `22 F1 90` and pending/confirmed DTCs `19 02 0C`, initially addressed from tester `F4` to DME `12` on TCP 6801. These assumptions require hardware validation.
- No arbitrary commands, clearing, session changes, resets, coding, flashing, or security access are exposed.
- Failure retains `faults: null`; only a valid successful response may produce an empty list. Gateway acknowledgements alone do not count as code reads.
- Reports and raw frames are saved locally only on user action (or an explicit CLI output path). There are no online dependencies, proprietary diagnostic databases, inferred definitions, or automatic uploads.
- Windows UI startup and actual adapter/vehicle behavior remain to be tested. The simulated tests establish software behavior only.

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
