# Architecture

Doc Otto is an iOS vehicle-diagnostics application. Implementation has not started, so most technical choices remain intentionally undecided.

## Current Direction

The first architecture should support a simple diagnostic path:

1. The iPhone joins or reaches the OBD scanner over Wi-Fi.
2. Doc Otto opens a network connection to the scanner.
3. The app communicates with the vehicle through the scanner using the appropriate OBD protocol/command layer.
4. The app requests diagnostic trouble codes (DTCs).
5. Returned fault codes are parsed into a stable internal representation.
6. The UI presents the detected codes clearly to the user.

Keep scanner/network communication separate from code parsing and from the UI so future diagnostic features can be added without tightly coupling the app to one screen or one adapter implementation.

## Boundaries To Preserve

- iOS UI and application state.
- Wi-Fi/network transport to the OBD scanner.
- OBD command/protocol handling.
- Diagnostic trouble code parsing and representation.
- Future code-description or repair-information data sources.

No specific OBD adapter, command set, networking library, persistence layer, or external diagnostic-data source has been selected yet.

## Engineering Principles

- Keep vehicle communication behavior explicit and testable.
- Avoid coupling the app to one scanner model unless that is an intentional product decision.
- Treat commands that can alter vehicle state differently from read-only diagnostic operations.
- Keep secrets, API keys, and credentials outside the repository.
- Prefer deterministic validation and reproducible local workflows.
- Record durable architecture decisions in `.ai/decisions/`.
