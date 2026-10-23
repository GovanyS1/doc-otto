# Local Windows MHD proof of concept

Status: Active

## Intent

Test whether Windows can receive fault codes from the test vehicle through the MHD Universal Wi-Fi adapter before mobile implementation.

## Constraints

- Publish the prepared changes through a pull request titled `Initial testing`, as authorized by the user. Do not merge it or create a separate tracking issue.
- Preserve the generic OBD-II product roadmap.
- Read requests only. No clearing, session changes, resets, coding, flashing, or security access.
- Do not claim hardware compatibility based on simulated tests.

## Completed

- Added the standalone desktop/CLI prototype, Windows launcher, instructions, and 18 simulated-gateway tests under `DocOtto/Prototypes/WindowsMhd`.
- Added VIN and pending/confirmed DME reads, strict response parsing, failure-aware results, and local raw-frame JSON export.
- Recorded the experimental scope and its validation limits in durable project context.
- Replaced specific vehicle references with `test vehicle` in the interface, reports, and project notes.
- Added the simulator tests to the GitHub pull-request validation job.

## Remaining

- Run the Windows GUI with Python/Tcl/Tk installed.
- Test discovery, real ENET forwarding, ECU addressing, and code reads with the MHD adapter and test vehicle.
- Save a report, compare engine pending/confirmed codes against MHD, and repeat scans.
- Use actual findings to decide the first mobile milestone.

## Validation

- All 18 simulated-gateway tests passed in both the preparation environment and the user's local checkout (Python 3.14.4).
- `ai validate .` passed all three checks, including the prototype tests; `git diff --check` passed.
- Actual Windows UI, adapter, and vehicle testing remains pending.

## Started

2026-10-23
