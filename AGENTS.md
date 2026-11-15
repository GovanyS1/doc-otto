# Doc Otto Development Guide

Read `README.md` and `.ai/` before making changes.

Git is authoritative for code/history. `.ai/` stores durable product intent, architecture context, decisions, and work packets that Git alone cannot express.

## Normal workflow

Start in the repository root and review the current branch and working tree:

```bash
git status
```

Coordinate any branch update with other contributors before pulling, and preserve existing local work. The optional `ai` workflow CLI can maintain task packets when installed:

```bash
ai status .
ai start "describe the task clearly"
```

If `ai` is unavailable, use `README.md` and the `.ai/` documents directly and record material decisions or handoffs in `.ai/work/` or `.ai/decisions/`. Do not install tools or change global configuration solely to follow this guide.

When installed, `ai start` creates or resumes `.ai/ACTIVE`, creates a work packet under `.ai/work/`, and recommends a work route:

- `none` - deterministic tooling is enough.
- `sol` - hosted engineering/product work.
- `astra` - work requiring additional reasoning, review, or care, such as security, privacy, concurrency, or critical correctness.

These are optional workflow suggestions, not required tools or model choices. Developers may use their own approved editor and assistant. For an assistant with repository access, a concise task prompt is sufficient:

```text
Work on the active task. Follow AGENTS.md.
```

Keep `.ai/CURRENT.md`, `.ai/ARCHITECTURE.md`, `.ai/decisions/`, and the active work packet current when the work materially changes them.

Validate before declaring work complete. If the `ai` CLI is installed, run:

```bash
ai validate .
```

Otherwise, inspect `.ai/validate.toml` and run the applicable checks with the required local SDKs or toolchains. Platform-dependent tests can be run on a suitable machine or in CI; document checks that could not be run.

If using the `ai` CLI, `ai finish` runs deterministic validation while keeping a task active:

```bash
ai finish .
```

When a task is complete, optionally close it through `ai finish . --complete` if the CLI is installed. In all environments, review the working tree:

```bash
git status
git diff
```

Then commit/push only when explicitly requested.

Delivery changes should normally go through a pull request targeting `main`.
GitHub runs the repository validation workflow on every pull request, and `main`
is protected so the required `validate` check must pass before merge.

When using the `ai` CLI, abandon an active task intentionally with:

```bash
ai stop --reason "Reason for abandoning the work"
```

## Optional fallback transport

When working without direct repository access, the `ai` CLI also supports these optional transport commands:

```bash
ai pack . --task "task"
ai apply implementation.zip --path .
ai finish . --pack
```

`ai pack` and `ai apply` are deterministic fallback tools. They are not part of normal `ai start` / `ai finish` usage.

## Durable context

- `.ai/PRODUCT.md` - product vision, scope, and durable product intent.
- `.ai/ARCHITECTURE.md` - architecture decisions and constraints.
- `.ai/CURRENT.md` - current high-level handoff.
- `.ai/decisions/` - durable decisions that should outlive a chat.
- `.ai/work/` - task work packets.
- `.ai/ACTIVE` - local active-task pointer; never committed.
- `.ai/out/` - generated fallback bundles; never committed.

Do not rely on chat history as the only record of an important decision.

## Engineering rules

- Preserve unrelated working-tree changes.
- Do not commit, push, merge, publish, deploy, or delete branches unless explicitly requested.
- Do not use `sudo` or alter OS services, credentials, SSH configuration, or system files unless explicitly requested.
- Avoid destructive filesystem or Git commands when a reversible alternative exists.
- Never commit secrets, credentials, tokens, or private user data.
- Treat authentication, authorization, privacy, regulated data, and destructive operations as high-risk work.
- Do not silently change product or architecture decisions.
- Prefer the simplest implementation that preserves correctness, security, and product intent.
