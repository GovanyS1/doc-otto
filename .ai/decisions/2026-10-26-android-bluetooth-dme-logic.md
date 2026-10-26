# Android Bluetooth DME logic foundation

Date: 2026-10-26

## Decision

The user requested the same initial diagnostic implementation for Android, continuing the UI-independent scope of the Swift work.

Add DocOtto/App/AndroidDiagnostics as Java core and Android BLE library modules. Keep the core independent of Android/JVM dependencies so it can be compiled/tested on Linux with JDK 17 and Java 8-targeted bytecode. The Android bridge targets API 26+ and compiles against API 35.

Use the same two UDS reads, strict VIN/fault parsing, physical 11-bit CAN routing, ELM setup/flow control, and partial-status semantics as Swift. BLE selection/profile and vehicle CAN routing remain caller-supplied and unverified.

## Boundaries

- Development was initially local. The user subsequently authorized committing, pushing, and opening the native diagnostic PR; deployment, merging, and tracking issues remain outside this request.
- No UI or app executable, generic service 03, descriptions, clearing, ECU writes, authentication bypass, or production compatibility claim.
- This adds an Android diagnostic foundation; it does not define a second complete 30-feature product roadmap.
- Run blocking scans on caller-owned workers. Interruption/cancellation closes the active link. The Android implementation serializes GATT operations, verifies CCCD and write callbacks, bounds queued data, and closes its callback thread.
- An empty list is valid only after a complete positive read. Pending-only and broken transport responses remain inconclusive.

## Evidence and follow-up

35 simulated core tests passed, including a full BLE/ELM/CAN/UDS scan, cancellation during read/write/open, concurrency, malformed replies, and empty-versus-failed reads.

The Android bridge compiled with warnings treated as errors against Google's AOSP API 35 reference jar, verified to Git blob 1c91b02611ddcf9aba606e01e28b0cdab9c57af1. This does not execute Android framework callbacks.

Full Gradle/AAR packaging, runtime permissions/manifest integration, a host app, actual adapter settings/CAN routing, and physical Android/vehicle tests remain pending.
