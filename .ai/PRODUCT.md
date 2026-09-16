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

## Initial User Goal

A user with a compatible Wi-Fi OBD scanner should be able to connect their iPhone to the scanner, request the vehicle's stored diagnostic trouble codes, and see the returned codes without needing separate diagnostic software.

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
