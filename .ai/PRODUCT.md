# Doc Otto

## Product Vision

Give iOS users a straightforward way to connect to a vehicle's OBD scanner over Wi-Fi and understand the fault codes reported by the vehicle.

The initial experience should feel roughly like:

Connect to scanner -> scan vehicle -> see fault codes.

## Initial Scope

- iOS application.
- Connect to a compatible OBD scanner over Wi-Fi.
- Read vehicle diagnostic trouble codes (fault codes).
- Present the detected codes clearly in the app.
- Let users open relevant online documents for a detected fault code.
- Let users generate and share a diagnostic fault-code report by email.

## Initial User Goal

A user with a compatible Wi-Fi OBD scanner should be able to connect their iPhone to the scanner, request the vehicle's stored diagnostic trouble codes, and see the returned codes without needing separate diagnostic software.

After a scan, the user should also be able to open relevant online documentation for a fault code and share the scan results as a diagnostic report, including by email.

## Diagnostic Documents

- Each detected fault code may include links to relevant online documentation.
- Documentation should be matched to the code and, when possible, the applicable vehicle.
- Prefer legitimate public, manufacturer, or licensed sources rather than redistributing copyrighted repair manuals without permission.
- Keep document metadata and links separate from the core fault-code representation so sources can be updated independently of the iOS app.

## Diagnostic Report Sharing

- Users should be able to generate a clear fault-code report after a scan.
- The report should support sharing through the normal iOS share flow, including email.
- The report may include vehicle information, scan date and time, detected codes, human-readable descriptions, code status, and related document links when available.
- Sharing should use the user's normal iOS sharing or mail experience rather than requiring Doc Otto to store email credentials.

## Future Direction

Doc Otto is expected to gain additional vehicle and diagnostic features over time. Those features are intentionally not defined yet and should be added to this durable product context as decisions are made.

Possible future capabilities should not be treated as committed scope until explicitly decided.

## Product Principles

- Keep the core diagnostic flow straightforward.
- Make scanner connection state and diagnostic results easy to understand.
- Keep the first version focused on reliable read-only diagnostics.
- Keep product intent explicit and durable in the repository.
- Do not assume future features before they are decided.
- Record meaningful product decisions in `.ai/decisions/` when they should outlive a chat.

## Open Product Questions

- Which Wi-Fi OBD scanners should be supported first?
- Which OBD-II protocols and vehicle model years are in the initial compatibility target?
- Should the first version only display raw DTCs or also include human-readable descriptions?
- Should code descriptions and possible fixes come from bundled data, an external API, or another source?
- Which additional diagnostic features should follow fault-code reading?
