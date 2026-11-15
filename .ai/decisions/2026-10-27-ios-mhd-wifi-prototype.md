# Native iOS MHD Wi-Fi prototype

Date: 2026-10-27
Status: Accepted for local prototype; physical iPhone compatibility pending

## Context

The project began an iOS prototype connecting through MHD over Wi-Fi. The
repository includes the Windows MHD ENET experiment and reusable Swift UDS
parsers. Initial Windows hardware testing reportedly returned VIN and code
records from a test vehicle. No verified diagnostic endpoint is stored in the repository.

## Decision

- Build a native SwiftUI iPhone app at `DocOtto/App/iOS`, targeting iOS 16+.
- Add ENET/HSFZ TCP to the existing Swift package and reuse its UDS reader/parsers.
- Use MHD Universal ENET mode and the Windows experiment's tester F4, DME 12,
  TCP 6801, VIN 22 F1 90, and pending/confirmed 19 02 0C.
- Require the verified local gateway IPv4 address; do not guess an adapter IP or
  assume an ELM327 interface.
- Use Network.framework with physical iOS Wi-Fi routing and Local Network
  permission. Manual network joining and unicast TCP keep first-device testing
  independent of Apple's restricted multicast/broadcast entitlement.
- Display raw code numbers/statuses; preserve the separate generic OBD-II roadmap.
- Keep demo results explicitly synthetic and failure distinct from an empty read.
- Export local JSON/raw-frame reports through the iOS share sheet on user action.
- Keep this task local: no commit, push, issue, PR, publishing, or credential changes.

## Consequences

Simulator builds, parser tests, native loopback scans, and model tests can verify
software behavior. Physical iPhone operation still requires Xcode development
signing and a scan against the actual MHD/test-vehicle setup. Adapter discovery,
CAN mode, generic OBD-II P-codes and code clearing are outside this prototype.
