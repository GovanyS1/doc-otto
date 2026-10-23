# Local Windows MHD Feasibility Experiment

Date: 2026-10-23
Status: Accepted for experiment; hardware compatibility unverified

## Context

The user wants to test whether a PC can receive fault codes through an MHD Universal Wi-Fi adapter before committing to mobile implementation. The first target is the test vehicle. Development began locally; the user subsequently authorized committing and pushing the prepared files and opening a pull request titled `Initial testing`.

## Decision

- Build a small standalone Windows Python prototype under `DocOtto/Prototypes/WindowsMhd`, separate from `DocOtto/App`.
- Initially test BMW ENET/HSFZ discovery and raw DME pending/confirmed fault reads, with an optional VIN read. Do not assume an ELM327 interface.
- Limit requests to `22 F1 90` and `19 02 0C`. Use TCP 6801, UDP discovery 6811, tester `F4`, and initial DME address `12`, all subject to validation on the actual setup.
- Display raw BMW hexadecimal fault codes and reported status bits, without proprietary definitions or automatic generic `Pxxxx` translations.
- Include a small desktop window, CLI, local raw-response report, and simulated-gateway validation.
- Publish the prepared prototype through the authorized `Initial testing` pull request. Work tracking remains in the repository; no separate GitHub issue is needed. Actual Windows/adapter/vehicle validation remains pending.

## Success Criteria

- A complete valid engine ECU DTC response is received on Windows through the real MHD adapter.
- Returned records can be compared with the corresponding engine pending/confirmed records from MHD, with repeatable reconnection.
- A valid empty response is distinguished from transport failures and rejected requests. An empty scan alone does not demonstrate parsing of a real fault record.

## Consequences

- Actual hardware and Windows GUI validation remain pending. Simulation is insufficient to claim compatibility.
- A BMW-specific ENET result does not establish generic OBD-II, other vehicle brands, other modules, or the adapter's CAN-mode compatibility.
- The accepted generic mobile roadmap remains in force. Choosing a mobile framework and production adapter strategy remains a later decision.
