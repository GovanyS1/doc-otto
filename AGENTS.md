# Doc Otto Development Guide

Read `README.md` and `.ai/` before making changes.

Git is authoritative for code/history. `.ai/` stores durable product intent, architecture context, decisions, and work packets that Git alone cannot express.

## Normal workflow

Run from the repository root:

```bash
git pull --ff-only
git status
ai status .
ai start "describe the task clearly"
```

`ai start` creates or resumes `.ai/ACTIVE`, creates a work packet under `.ai/work/`, and recommends one of three routes:

- `none` - deterministic tooling is enough.
- `sol` - normal hosted engineering/product work. Use GPT-5.6 Sol with direct repository access.
- `astra` - difficult or high-risk work such as security, privacy, privilege boundaries, concurrency, cryptography, regulated data, or critical correctness. Treat this as the team's highest-reasoning route.

For hosted routes, work directly in the repository with ChatGPT. Chat On Steroids is the recommended bridge. A concise prompt is enough:

```text
Work on the active task. Follow AGENTS.md.
```

Keep `.ai/CURRENT.md`, `.ai/ARCHITECTURE.md`, `.ai/decisions/`, and the active work packet current when the work materially changes them.

Validate before declaring work complete:

```bash
ai validate .
```

Use `ai finish` when you only want deterministic validation and the task should remain active:

```bash
ai finish .
```

When the task is actually complete:

```bash
ai finish . --complete
git status
git diff
```

Then commit/push only when explicitly requested.

Delivery changes should normally go through a pull request targeting `main`.
GitHub runs the repository validation workflow on every pull request, and `main`
is protected so the required `validate` check must pass before merge.

To abandon the active task intentionally:

```bash
ai stop --reason "Reason for abandoning the work"
```

## Fallback-only transport

Direct repository access is the normal workflow. Use these only when that is unavailable:

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
