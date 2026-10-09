# Architecture

Doc Otto is an iOS vehicle-diagnostics application. Implementation has not started, so most technical choices remain intentionally undecided. The product roadmap includes both Wi-Fi and BLE scanner transports, although the first supported adapter and transport remain to be selected.

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
