# Current Work

Doc Otto has been bootstrapped with its AI-assisted development workflow. Its high-level product purpose is now recorded, but implementation has not started.

## Completed

- Created the repository workflow guide.
- Added durable `.ai/` product, architecture, and current-work context.
- Added deterministic baseline validation.
- Defined Doc Otto at a high level as an iOS app that connects to a vehicle's OBD scanner over Wi-Fi and reads fault codes.
- Defined the initial user flow as connecting to the scanner, scanning the vehicle, and viewing diagnostic trouble codes.
- Recorded provisional architecture boundaries for network transport, OBD communication, code parsing, and UI.

## Next

No implementation work is currently planned.

Before development begins:

- Identify the first supported Wi-Fi OBD scanner or scanner family.
- Confirm the scanner's network protocol and command behavior.
- Decide the minimum supported vehicle/OBD-II compatibility target.
- Decide whether the first milestone displays raw DTCs only or includes descriptions.
- Define the first implementation milestone before running `ai start`.

## Needs Review

- Supported OBD scanner/protocol scope.
- Initial iOS technical architecture.
- First implementation milestone.
- Future diagnostic and vehicle features.
