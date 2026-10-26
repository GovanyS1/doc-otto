# Doc Otto

Doc Otto is an iOS vehicle diagnostics app that connects to a car's OBD scanner over Wi-Fi and reads diagnostic trouble codes (fault codes) reported by the vehicle.

The initial focus is connecting to the scanner and making fault codes available in the app. Additional vehicle and diagnostic features can be added later as the product evolves.

Before mobile implementation, a local [Windows MHD experiment](DocOtto/Prototypes/WindowsMhd/README.md) tests raw engine fault reads through an MHD Universal Wi-Fi adapter. The user reports successful VIN and code-number reads from the test vehicle; broader compatibility remains unverified.

Initial native diagnostic logic is in [DocOtto/App/Diagnostics](DocOtto/App/Diagnostics/README.md). This Swift package contains a configurable BLE/ELM327 CAN transport and raw UDS engine-fault reader, without UI. Its simulated tests run on Linux; the BLE adapter profile, vehicle CAN route, and physical iPhone operation remain unverified.

The same initial diagnostic logic is also available for [Android](DocOtto/App/AndroidDiagnostics/README.md), using a dependency-free Java core and an Android BLE library. It includes no UI or APK. JVM tests and Android API source compilation do not establish physical-device or vehicle compatibility.
