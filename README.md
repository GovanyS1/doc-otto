# Doc Otto

Doc Otto is an iOS vehicle diagnostics app that connects to a car's OBD scanner over Wi-Fi and reads diagnostic trouble codes (fault codes) reported by the vehicle.

The initial focus is connecting to the scanner and making fault codes available in the app. Additional vehicle and diagnostic features can be added later as the product evolves.

The first runnable native [iOS MHD Wi-Fi prototype](DocOtto/App/iOS/README.md) is in `DocOtto/App/iOS/DocOtto.xcodeproj`. It includes SwiftUI connection setup, VIN/raw engine-code results, an explicit demo, and local report sharing. It uses the MHD Universal adapter's ENET path, with optional automatic HSFZ Wi-Fi gateway discovery and a manual IP fallback. Physical iPhone/adapter/vehicle validation remains pending; automatic iOS broadcast discovery requires Apple's restricted multicast networking entitlement.

Before mobile implementation, a [Windows MHD experiment](DocOtto/Prototypes/WindowsMhd/README.md) was used to test raw engine fault reads through an MHD Universal Wi-Fi adapter. Initial hardware testing reported VIN and code-number reads; broader compatibility remains unverified.

Shared native diagnostic logic is in [DocOtto/App/Diagnostics](DocOtto/App/Diagnostics/README.md). This Swift package contains ENET Wi-Fi and configurable BLE/ELM327 CAN transports plus a raw UDS engine-fault reader. It remains independent of the app UI. The BLE adapter profile, vehicle CAN route, and physical iPhone operation remain unverified.

The same initial diagnostic logic is also available for [Android](DocOtto/App/AndroidDiagnostics/README.md), using a dependency-free Java core and an Android BLE library. It includes no UI or APK. JVM tests and Android API source compilation do not establish physical-device or vehicle compatibility.
