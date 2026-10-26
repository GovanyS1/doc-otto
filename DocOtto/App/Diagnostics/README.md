# Doc Otto diagnostic logic

This Swift package contains the initial iOS diagnostic logic. It has no screens or app executable. It targets iOS 16+ and macOS 13+; the protocol core and simulated transports also run on Linux.

## Assumptions and current limits

- The connection is **Bluetooth Low Energy**, using a documented UART-style GATT service carrying ELM327-compatible ASCII commands.
- The adapter supports classical CAN, normal ISO-TP addressing, raw frame output, receive filters, and configurable automatic flow control.
- The caller supplies the selected peripheral ID, service/write/notification UUIDs, write mode, physical engine ECU request/response CAN IDs, and CAN bit rate.
- **No real adapter profile or test-vehicle CAN route is bundled.** The 7E0/7E8 identifiers and FFF0/FFF1/FFF2 UUIDs in tests are fixtures, not a BMW compatibility claim. The Windows ENET DME address 12 cannot be substituted for a CAN ID.
- Only VIN (22 F1 90) and pending/confirmed raw UDS faults (19 02 0C) are requested. This does not read every stored/history fault, implement generic OBD-II service 03, or map raw fault numbers to definitions.
- BMW DME access through a BLE adapter is unverified. Some vehicles require other routing, extended addressing, gateway access, or protocols not implemented here. The existing MHD Wi-Fi experiment is a different connection path.
- Bluetooth Classic serial adapters, 29-bit CAN, CAN FD, ECU discovery/address guessing, code clearing, session changes, coding, programming, and security access are outside this implementation.

## Files and scan flow

| File | Responsibility |
|---|---|
| CoreBluetoothByteStream.swift | Connect to the selected peripheral, validate configured GATT characteristics, subscribe to notifications, and write with the configured response mode |
| PromptCommandChannel.swift | Assemble fragmented ASCII notifications through the ELM prompt; serialize requests, enforce timeouts, handle cancellation, and keep a bounded in-memory trace |
| ELM327Transport.swift | Configure the adapter and physical CAN route, send the two supported single-frame read requests, and validate reply addresses |
| ISOTP.swift | Validate frame ordering/length and assemble multiline CAN replies |
| Diagnostics.swift | Validate VINs, extract three-byte raw fault IDs and status bits, and orchestrate a scan |

DMEReader creates a fresh transport for each scan, opens it, reads the VIN, reads fault records, and closes it. A complete VIN rejection permits the fault read to continue. A VIN timeout, incomplete message, or malformed VIN stops the scan because the connection is no longer trustworthy.

Adapter reset ATZ affects the adapter, not the vehicle ECU. Initialization requires a recognized startup banner and OK for every required setup command; unsupported commands stop the scan before vehicle requests.

FaultRead.faults can be an empty list only after a valid positive ECU response. NO DATA, missing prompts, disconnects, unsupported statuses, incomplete CAN sequences, unexpected ECU addresses, and negative responses throw errors. Callers must present those failures as unknown code status. If the ECU supports only part of the requested status mask, evaluatedStatusMask and unavailableStatusMask make that limitation explicit.

A response-pending reply can precede a final response within one bounded adapter transaction. Pending without a final response is inconclusive; the package does not resend the request or extend the deadline indefinitely.

## Integrating with a future iOS app

Open Package.swift in Xcode or add this directory as a local Swift package. Import DocOttoDiagnostics from the app target. The containing app must include an NSBluetoothAlwaysUsageDescription string explaining its adapter connection; the library does not supply an app Info.plist.

The future caller selects/discovers a peripheral first. CoreBluetoothByteStream connects only to that supplied peripheral ID. Its fallback scan filters by the configured service UUID, which must be advertised if the peripheral is not already known to Core Bluetooth. It does not connect to the first device with a matching name.

This function accepts externally verified configuration, without sample production addresses:

```swift
import DocOttoDiagnostics
import Foundation

@MainActor
func makeReader(
    peripheralID: UUID,
    serviceUUID: String,
    writeUUID: String,
    notifyUUID: String,
    writeMode: BLEAdapterProfile.WriteMode,
    requestCANID: UInt16,
    responseCANID: UInt16,
    bitRate: CANConfiguration.BitRate
) throws -> DMEReader {
    let profile = try BLEAdapterProfile(
        peripheralID: peripheralID,
        serviceUUID: serviceUUID,
        writeUUID: writeUUID,
        notifyUUID: notifyUUID,
        writeMode: writeMode
    )
    let can = try CANConfiguration(
        requestID: requestCANID,
        responseID: responseCANID,
        bitRate: bitRate
    )
    return DMEReader {
        let stream = try CoreBluetoothByteStream(profile: profile)
        let channel = try PromptCommandChannel(stream: stream, timeout: 12)
        return ELM327Transport(channel: channel, configuration: can)
    }
}

// From a foreground async task:
// let result = try await reader.scan(targetLabel: "test vehicle")
// result.vin
// result.faultRead.faults
// Handle errors and CancellationError explicitly; do not substitute [] on failure.
```

No vehicle data is persisted or sent online. EngineScan and WireEvent are Codable so an eventual caller can explicitly choose to save/share them. The command channel retains at most 64 trace events in memory.

## Testing on Linux or a Mac

```bash
bash test.sh
```

The runner uses an installed Swift toolchain, or an already-downloaded official swift:6.0.3-jammy Docker image. It does not install packages, start a privileged container, or download an image automatically. If needed on Linux, explicitly run docker pull swift:6.0.3-jammy first. Docker tests have networking disabled and run as the current user.

Tests use scripted byte streams and ECU replies, including an end-to-end simulated BLE/ELM/ISO-TP/UDS scan. These are not real iPhone, radio, adapter, or vehicle tests. Linux does not compile the Core Bluetooth implementation guarded by canImport(CoreBluetooth); an Apple SDK build and device testing remain required.

## Protocol references

- [Apple Core Bluetooth](https://developer.apple.com/documentation/corebluetooth)
- [Apple peripheral write limits](https://developer.apple.com/documentation/corebluetooth/cbperipheral/maximumwritevaluelength(for:))
- [ELM327 manufacturer datasheet](https://www.elmelectronics.com/wp-content/uploads/2017/01/ELM327DS.pdf), especially raw CAN formatting, receive filtering, flow control, and response-pending handling
