# Current Work

Doc Otto's mobile implementation has not started. A separate local Windows/Python experiment now exists at `DocOtto/Prototypes/WindowsMhd` to test MHD Universal Wi-Fi communication with the test vehicle before committing to mobile implementation. It reads raw BMW engine fault records; actual adapter/vehicle compatibility remains unverified.

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

## Next

The software prototype is ready for a first Windows test with the MHD adapter and test vehicle. The user authorized committing and pushing the prepared files and opening a pull request titled `Initial testing`. Actual Windows/adapter/vehicle testing remains pending.

First experimental milestone:

- Run `DocOtto/Prototypes/WindowsMhd/start_windows.cmd` on Windows with Python 3.10+ and Tcl/Tk installed.
- Connect Windows to the MHD adapter's ENET Wi-Fi network, select that PC interface, and read the engine codes.
- Save the scan report, compare like-for-like engine pending/confirmed records with MHD, and check repeatability.
- Record the actual adapter firmware/mode and working network endpoint once established. Treat discovery/ECU/transport failures as unknown code status.
- A valid empty reply proves a successful read transaction; matching an existing code with MHD also validates record parsing on the test vehicle. Do not deliberately induce faults for the test.

Before mobile development begins:

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
- Initial iOS technical architecture.
- Windows UI startup and actual compatibility between the MHD adapter and test vehicle; TCP 6801/HSFZ access and DME address `12` are initial assumptions.
- Mobile implementation milestone; a BMW-specific raw read does not establish generic OBD-II or cross-brand support.
- Roadmap release sequencing.
- Diagnostic-content sourcing, licensing, and review.
