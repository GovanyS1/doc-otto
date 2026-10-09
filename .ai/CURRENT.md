# Current Work

Doc Otto has been bootstrapped with its AI-assisted development workflow. Its high-level product purpose is now recorded, but implementation has not started.

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

## Next

No implementation work is currently planned.

Before development begins:

- Identify the first supported Wi-Fi OBD scanner or scanner family.
- Identify the first supported BLE OBD scanner or scanner family.
- Confirm the scanner's network protocol and command behavior.
- Decide the minimum supported vehicle/OBD-II compatibility target.
- Select a licensed or otherwise distributable source for offline generic DTC definitions.
- Define the review process for common-cause and guided-checklist content.
- Divide the committed product roadmap into release milestones.
- Define the first implementation milestone before running `ai start`.

## Needs Review

- Supported OBD scanner/protocol scope.
- Initial iOS technical architecture.
- First implementation milestone.
- Roadmap release sequencing.
- Diagnostic-content sourcing, licensing, and review.
