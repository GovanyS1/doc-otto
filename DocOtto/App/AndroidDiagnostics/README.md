# Doc Otto Android diagnostic logic

A UI-independent Android counterpart to the Swift package in ../Diagnostics. It uses the same read-only UDS payloads, raw fault/status interpretation, and BLE/ELM327/CAN protocol layers.

This is library source, not an APK. It includes no screens, activity, launcher, service, scanning UI, or installed application.

## Modules and requirements

| Module | Role |
|---|---|
| core | Dependency-free Java diagnostic logic, executable and testable on a desktop JVM |
| ble | Android Bluetooth GATT byte stream using a caller-selected BluetoothDevice and documented adapter profile |

The Android module requires Android 8.0/API 26+. Gradle configuration uses compileSdk 35, Android Gradle Plugin 8.7.3, Gradle 8.9, and JDK 17. Source and bytecode are Java 8 compatible. No Gradle wrapper is bundled; open the project with a matching Android Studio/Gradle installation or generate the standard wrapper there.

The standalone tests need JDK 17 or a previously downloaded official eclipse-temurin:17-jdk-jammy Docker image. They need no Maven dependencies, Android device, or network connection.

## Implemented scan flow

1. The caller supplies a selected BLE device, service/write/notification UUIDs, supported write mode, physical DME request/response CAN IDs, and CAN bit rate.
2. AndroidBleByteStream connects on a worker, discovers the configured service/characteristics, enables local notifications, and writes the remote CCCD. Connection readiness requires successful descriptor acknowledgement.
3. PromptCommandChannel sends ASCII commands terminated by CR and accumulates arbitrary BLE fragments through the ELM prompt. One monotonic deadline covers writing and receiving each command.
4. Elm327Transport checks the adapter banner and required setup responses, selects an explicit normal-addressed 11-bit CAN route, and configures automatic flow control.
5. DmeReader requests VIN 22 F1 90, then pending/confirmed fault records 19 02 0C. Only these vehicle requests are exposed. ATZ resets the adapter, not the vehicle ECU.
6. IsoTpAssembler validates and reassembles the CAN replies. Uds validates VINs and extracts raw three-byte fault identifiers and supported status flags.
7. The scanner always closes its transport. A complete VIN rejection permits the code read; a timeout, incomplete VIN, or malformed response ends the scan.

A positive empty fault response is a successful empty result. NO DATA, a missing prompt, a wrong ECU, truncated CAN messages, unsupported requested statuses, and transport failure throw errors. Treat those errors as unknown code status. Partial ECU status support is explicit through evaluatedStatusMask() and unavailableStatusMask().

Response-pending followed by a final response within the same adapter transaction is accepted. Pending without a final response remains inconclusive. The library does not resend vehicle requests or extend the deadline indefinitely.

## Important compatibility limits

No production adapter profile or verified vehicle CAN route is bundled. The test fixture IDs 7E0/7E8 and example UUID values in any tests do not establish BMW compatibility. The successful Windows/MHD ENET experiment is a different transport and addressing path.

This version assumes a documented BLE UART-style service carrying ELM327-compatible text, classical CAN at 250/500 kbps, normal ISO-TP addressing, and readable UDS services. It does not implement Bluetooth Classic SPP, 29-bit CAN, extended addressing, CAN FD, K-line, Ethernet diagnostics, ECU/address discovery, generic OBD-II service 03, code descriptions, clearing, ECU session changes, coding, programming, or security access.

Notifications and GATT write acknowledgements are checked independently from diagnostic results. Both configured write modes are supported; every command still requires a complete ELM/ECU result. Commands fit within the baseline 20-byte BLE payload, so no MTU negotiation or chunking is performed.

## Permissions and threading

The library manifest declares BLUETOOTH for Android 11 and earlier and BLUETOOTH_CONNECT for Android 12+. The containing app must request the applicable runtime permission before connecting. The library detects denial/revocation and reports failure.

Device selection/discovery is the future caller's responsibility. If the host scans for adapters, it must also handle the scan permissions appropriate to its Android version, including BLUETOOTH_SCAN on Android 12+ and any applicable earlier location permissions. No automatic permission dialog or pairing UI is included.

All diagnostic I/O is blocking and must run on an ExecutorService or another worker. The Android bridge rejects main-thread blocking. GATT callbacks use a private HandlerThread. Cancellation, disconnects, and deadlines unblock waits and close the session; no diagnostic callbacks should update UI directly.

## Integrating with a future app

The Android library module exposes the core module. Add these two modules to the host Gradle build, or include this project as a composite build and depend on its ble library. The build is a source starting point; full Gradle/AAR packaging still needs validation in an Android SDK installation.

The following factory accepts actual configuration, without guessed production addresses:

```java
import android.bluetooth.BluetoothDevice;
import android.content.Context;
import com.docotto.diagnostics.*;
import com.docotto.diagnostics.ble.*;

static DmeReader makeReader(
        Context context,
        BluetoothDevice selectedDevice,
        BleAdapterProfile profile,
        CanConfiguration verifiedCanRoute) {
    return new DmeReader(() -> {
        AndroidBleByteStream stream =
                new AndroidBleByteStream(context, selectedDevice, profile);
        PromptCommandChannel channel = new PromptCommandChannel(stream);
        return new Elm327Transport(channel, verifiedCanRoute);
    });
}

// From a foreground app component with a selected device and granted permission:
// ExecutorService worker = Executors.newSingleThreadExecutor();
// Future<Diagnostics.EngineScan> scan = worker.submit(() -> reader.scan());
// Handle the result/errors away from the main thread.
// scan.cancel(true); // Interrupts pending connection/write/read waits.
// worker.shutdown(); // Release the caller-owned executor when it is no longer needed.
```

Use a fresh stream/channel/transport for each scan. Do not call blocking Future.get() on the main thread. If a Future reports cancellation or a diagnostic exception, do not replace the failure with an empty fault list.

Results and the bounded in-memory wire trace remain local. Nothing is uploaded, persisted, or shared automatically. Serialization/report saving is left to a future caller.

## Testing on Linux

From this folder:

```bash
bash test.sh
```

The script compiles clean Java 8-targeted sources using JDK 17, treats warnings as errors, and runs 35 dependency-free core tests. Docker fallback runs as the current user with networking disabled. The runner never downloads tools automatically. If needed, explicitly run docker pull eclipse-temurin:17-jdk-jammy first.

To compile the Android bridge against an installed API 35 jar as well:

```bash
DOC_OTTO_ANDROID_JAR=/absolute/path/to/Android/Sdk/platforms/android-35/android.jar bash test.sh
```

The runner also detects API 35 under ANDROID_HOME/ANDROID_SDK_ROOT. In this local checkout, an ignored AOSP API 35 reference jar is available to repeat the source compilation. Its Git blob is 1c91b02611ddcf9aba606e01e28b0cdab9c57af1. The jar is an API reference, not an Android runtime or complete SDK.

With Gradle 8.9, JDK 17, and a configured Android SDK, the intended packaging/check commands are:

```bash
gradle :core:check :ble:assembleDebug
```

Completed validation: 35 JVM core tests and compilation of Android BLE Java sources against the API 35 reference jar. This does not test real Android callbacks, radio behavior, adapter/vehicle compatibility, runtime permissions, manifest merging, AAR packaging, or installation. Those remain separate checks.

## Platform references

- [Android BLE GATT connections](https://developer.android.com/develop/connectivity/bluetooth/ble/connect-gatt-server)
- [Android BLE data and notifications](https://developer.android.com/develop/connectivity/bluetooth/ble/transfer-ble-data)
- [Android Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)
- [BluetoothGatt API, including API 33 write overloads](https://developer.android.com/reference/android/bluetooth/BluetoothGatt)
- [Android Gradle Plugin 8.7 compatibility](https://developer.android.com/build/releases/agp-8-7-0-release-notes)
- [AOSP API 35 reference files](https://android.googlesource.com/platform/prebuilts/sdk/+/refs/heads/main/35/public/)
- [ELM327 manufacturer datasheet](https://www.elmelectronics.com/wp-content/uploads/2017/01/ELM327DS.pdf)
