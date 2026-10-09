# Doc Otto

## Product Vision

Give iOS users a straightforward way to connect to a compatible OBD scanner, understand standardized emissions-related fault codes, inspect supported live data, and keep a useful diagnostic and repair history.

The initial experience should feel roughly like:

Connect to scanner -> scan vehicle -> see fault codes.

## Initial Scope

- iOS application.
- Connect to a compatible OBD scanner over Wi-Fi.
- Read vehicle diagnostic trouble codes (fault codes).
- Present the detected codes clearly in the app.
- Let users open relevant online documents for a detected fault code.
- Let users generate and share a diagnostic fault-code report by email.

## Initial User Goal

A user with a compatible Wi-Fi OBD scanner should be able to connect their iPhone to the scanner, request the vehicle's stored diagnostic trouble codes, and see the returned codes without needing separate diagnostic software.

After a scan, the user should also be able to open relevant online documentation for a fault code and share the scan results as a diagnostic report, including by email.

## Diagnostic Scope

- Doc Otto supports standardized, generic emissions-related OBD-II diagnostics.
- Stored, pending, and permanent generic DTCs may be read when the vehicle and adapter expose them.
- Unsupported manufacturer-specific codes should be displayed as raw codes without an inferred or unverified definition.
- Doc Otto does not promise manufacturer-specific diagnostics, ABS or airbag access, coding, programming, bidirectional controls, or an automatic identification of the required repair.
- Scanner support must be defined through a tested compatibility list rather than a claim of universal adapter support.

## Diagnostic Documents

- Each detected fault code may include links to relevant online documentation.
- Documentation should be matched to the code and, when possible, the applicable vehicle.
- Prefer legitimate public, manufacturer, or licensed sources rather than redistributing copyrighted repair manuals without permission.
- Keep document metadata and links separate from the core fault-code representation so sources can be updated independently of the iOS app.

## Diagnostic Report Sharing

- Users should be able to generate a clear fault-code report after a scan.
- The report should support sharing through the normal iOS share flow, including email.
- The report may include vehicle information, scan date and time, detected codes, human-readable descriptions, code status, and related document links when available.
- Sharing should use the user's normal iOS sharing or mail experience rather than requiring Doc Otto to store email credentials.

## Committed Product Roadmap

The following features define the agreed product roadmap. They are not all required in the first implementation milestone and should be delivered in validated phases.

1. **User Authentication** - Create an account, sign in, and reset passwords.
2. **Multi-Car Profiles** - Save and manage multiple vehicles under one account.
3. **VIN Scanner and Decoder** - Scan or manually enter a VIN and retrieve basic vehicle information using NHTSA.
4. **Bluetooth OBD-II Connection** - Connect to a published list of tested BLE adapters.
5. **Wi-Fi OBD-II Connection** - Connect to supported Wi-Fi adapter families.
6. **Adapter Compatibility Check** - Test the adapter connection and show whether it is officially supported by Doc Otto.
7. **Generic DTC Scanning** - Read stored, pending, and permanent standardized emissions-related codes.
8. **Generic DTC Clearing** - Clear stored generic emissions-related codes after warning that freeze-frame data may be erased and readiness monitors may reset. Permanent codes cannot be manually cleared.
9. **Offline Code Definitions** - Display standardized generic-code definitions without an internet connection. Unsupported manufacturer-specific codes are displayed without an inferred definition.
10. **Freeze-Frame Data** - Display vehicle conditions recorded when a code was triggered.
11. **Readiness Monitors** - Show the status of emissions monitors for inspection preparation.
12. **Live Vehicle Data** - Display supported standard PIDs such as RPM, speed, throttle position, fuel trims, and intake temperature.
13. **Custom Dashboard** - Let users select, arrange, and remove live-data gauges.
14. **Coolant Temperature Monitoring** - Display coolant temperature and provide alerts during an active connection.
15. **Estimated Fuel Economy** - Calculate approximate fuel economy when the vehicle provides the required data.
16. **Scan and Sensor History** - Save previous scan results and selected live-data sessions.
17. **Mileage and Trip Log** - Allow users to enter mileage and maintain trip records.
18. **Scan Alerts and Reminders** - Alert users about codes detected during an active scan and schedule local reminders for future scans.
19. **Common Causes and Suggested Checks** - Show curated possible causes and general checks without claiming to provide a guaranteed diagnosis.
20. **Recall Lookup** - Search free NHTSA recall information and link to the official VIN-specific recall checker.
21. **Official Service Bulletin Search** - Open the appropriate NHTSA manufacturer-communications search without copying proprietary service information.
22. **Maintenance Planner** - Track maintenance dates, mileage intervals, completed services, and upcoming maintenance.
23. **Code Reappearance Tracker** - Record when a code was cleared and determine when it returns based on future scans, elapsed time, and entered mileage.
24. **Battery Voltage Monitor** - Display approximate voltage reported by the supported OBD adapter or standard voltage PID. This is not a professional battery load test.
25. **Guided Diagnostic Checklist** - Provide locally stored, reviewed checklists for common code categories. Users can record symptoms, complete safe checks, attach notes or photos, record actions taken, and run a follow-up scan.
26. **Repair Logbook** - Record repairs, replacement parts, costs, dates, mileage, receipts, and notes.
27. **Parts Research List** - Save candidate parts, prices, links, part numbers, and whether fitment has been independently verified.
28. **Diagnostic Report Export and Sharing** - Generate a PDF scan report and share it through email or the iOS share sheet.
29. **Multi-Language Support** - Provide supported interface and diagnostic-content translations stored in the application.
30. **Accessibility and Appearance** - Support screen readers, scalable text, sufficient contrast, system themes, and dark mode.

## Cost and Data Strategy

- Keep recurring external API costs low.
- Prefer on-device processing, bundled content, local notifications, and normal iOS share flows.
- NHTSA is the preferred public source for VIN decoding, recall information, and manufacturer-communication links.
- Supabase may provide authentication, synchronization, and cloud storage if those capabilities are enabled; the product should not add paid data services without an explicit decision.
- Diagnostic checklists and common-cause content must be curated, reviewed, stored locally, and written without copying proprietary repair procedures.
- Map, email, OEM-information, and similar actions should open the user's installed app or an official website when that avoids another paid integration.

## Future Direction

The committed roadmap above describes the intended product direction, but release sequencing remains undecided. The first implementation milestone should stay focused on a small, reliable scanner-connection and generic-DTC flow before later roadmap features are added.

Capabilities not listed in the committed roadmap should not be treated as approved scope until explicitly decided.

## Product Principles

- Keep the core diagnostic flow straightforward.
- Make scanner connection state and diagnostic results easy to understand.
- Keep the first version focused on reliable generic diagnostics.
- Treat DTC clearing and any other state-changing operation as a separate, confirmation-gated capability.
- Prefer a small tested compatibility matrix over unsupported universal-compatibility claims.
- Avoid presenting a generic DTC, checklist, or common cause as a confirmed diagnosis.
- Minimize recurring API and licensed-data costs.
- Keep product intent explicit and durable in the repository.
- Do not assume unlisted future features before they are decided.
- Record meaningful product decisions in `.ai/decisions/` when they should outlive a chat.

## Open Product Questions

- Which Wi-Fi OBD scanners should be supported first?
- Which BLE OBD scanner should be supported first?
- Which OBD-II protocols and vehicle model years are in the initial compatibility target?
- Which roadmap features belong in each release milestone?
- What licensed or otherwise distributable source will provide the offline generic DTC definitions?
- Who will review the locally bundled common-cause and diagnostic-checklist content?
- Is Supabase required for the first release, or can authentication and synchronization follow the local-only diagnostic milestone?
