# Native Bluetooth DME logic foundation

Date: 2026-10-26

## Decision

Implement a UI-independent Swift package at DocOtto/App/Diagnostics. The user requested diagnostic logic such as DME scanning, assuming Bluetooth, and explicitly deferred UI work.

Use a configurable BLE UART/ELM327 transport with classical CAN and normal ISO-TP addressing. The only vehicle requests are VIN 22 F1 90 and pending/confirmed raw DTC records 19 02 0C. Core Bluetooth is the Apple transport boundary; the UDS/CAN/adapter logic is portable and testable with scripted byte streams.

No actual BLE adapter, GATT profile, or engine ECU CAN route has been chosen or validated. These settings must be supplied explicitly; fixture addresses are not defaults. The Windows ENET route is not translated into CAN addresses.

This is an enhanced raw-UDS experiment and reusable native foundation, not evidence of universal scanner support or an expansion of the generic OBD-II product promise.

## Constraints

- Development was initially local. The user subsequently authorized committing, pushing, and opening the native diagnostic PR; deployment, merging, and new shared tracking issues remain outside this request.
- No UI, web prototype, app shell, paid service, manufacturer data, descriptions, or clearing.
- Preserve the existing Windows reader.
- A failed operation throws; only a complete positive diagnostic reply may produce an empty fault list.
- A complete VIN rejection permits code reading; a broken VIN transaction aborts the scan.
- Disconnect on timeout/cancellation or stream ambiguity, and create a fresh transport for each scan.
- Linux tests do not compile Apple Core Bluetooth. Apple SDK compilation and real iPhone/adapter/vehicle testing remain required.

## Evidence and follow-up

31 simulated Swift tests pass on Linux using the official Swift 6.0.3 toolchain in Docker. The container has networking disabled and uses the local user's identity. Existing Windows tests remain separate.

Next identify the BLE adapter and documented GATT command behavior, establish the test vehicle's physical CAN route, compile the package with an Apple SDK, and test read-only behavior on a physical iPhone.
