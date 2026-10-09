# Generic OBD-II Product Roadmap

Date: 2026-10-08
Status: Accepted

## Context

Doc Otto needed a concrete feature direction that a small team can build without relying on expensive manufacturer-specific diagnostic licenses, proprietary repair-price data, parts-fitment services, or several recurring paid APIs.

## Decision

- Adopt the 30-feature roadmap recorded in `.ai/PRODUCT.md`.
- Limit diagnostic promises to standardized, generic emissions-related OBD-II capabilities.
- Display unsupported manufacturer-specific codes without inventing or inferring a definition.
- Do not promise enhanced ABS, airbag, body-module, coding, programming, or bidirectional diagnostic features.
- Support only adapters and transports included in a tested compatibility matrix.
- Keep recurring API costs low by preferring bundled content, on-device behavior, NHTSA public resources, normal iOS share flows, and optional Supabase services.
- Replace repair-price comparison, manual quote comparison, and nearby-shop aggregation with a code reappearance tracker, battery voltage monitor, and guided diagnostic checklist.
- Treat the roadmap as a phased product direction rather than the scope of a single first release.

## Consequences

- The initial implementation can remain a small scanner-connection and generic-DTC milestone.
- Offline code definitions require a licensed or otherwise distributable source.
- Common-cause and guided-checklist content must be written, reviewed, versioned, and stored locally.
- DTC clearing requires explicit confirmation and accurate warnings about readiness monitors, freeze-frame data, and permanent codes.
- Manufacturer-specific diagnostic support would require a separate future decision, funding, licensing, implementation, and validation effort.
