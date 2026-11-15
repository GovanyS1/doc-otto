# Universal iOS OBD-II scan path and transport selection
Date: 2026-10-30
Status: Implemented locally; physical compatibility pending

Default iOS scanning now uses read-only generic SAE J1979 modes with ELM327 prompt framing. Users choose Wi-Fi TCP or BLE UART, and configure an explicit adapter endpoint/profile. Never infer adapter protocol from vehicle brand or identify a nearby BLE peripheral as a compatible scanner merely from its advertisement. The earlier MHD BMW ENET/HSFZ path remains separate and unmodified for legacy raw UDS reading. Standard DTCs are decoded in standard `P/C/B/U` format; no manufacturer-specific definitions are inferred. Pending and permanent read availability remains explicit. Results and export distinguish true clean reads from absent or malformed replies. No clearing, reprogramming or remote services.

Physical validation is required separately for each adapter family and supported vehicle protocol. Bluetooth Classic SPP ELM327 devices are outside the supported iOS transport path. Use manufacturer-verified GATT service/characteristic IDs and TCP host/ports.
