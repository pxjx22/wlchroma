# AI Contributing to wlchroma

This file tells AI agents how to contribute usefully to `wlchroma`.

Treat generic AI-collaboration advice as inspiration only. When repo guidance conflicts with generic advice, follow the repo.

## Source Of Truth Order

Use this order when deciding what to do:

1. `README.md`
2. `CONTRIBUTING.md`
3. relevant files under `specs/`
4. `CLAUDE.md`
5. existing code, tests, and CI

Do not invent architecture or workflow that is not implied by those sources.

## What To Optimize For

- correctness
- minimal diffs
- spec alignment
- docs parity
- explicit verification

Prefer the smallest correct change over a broad cleanup.

## When Specs Are Required

Add or update the relevant numbered spec under `specs/` when you change:

- config schema or config behavior
- CLI flags or commands
- IPC protocol or semantics
- runtime behavior visible to users or scripts
- major renderer behavior or fallback behavior

Small bug fixes, tests, and doc-only changes usually do not need a new spec.

## Working Rules

- Keep changes narrow and atomic.
- Do not mix refactors with behavior changes unless required.
- Do not silently change public behavior.
- Do not write speculative docs for behavior the code does not implement.
- Do not say a fix is complete if you only edited files and did not verify the result.

## Validation Rules

Run the narrowest command that proves the change, and run the CI-equivalent checks when relevant:

```bash
zig build
zig test src/config/config.zig
```

If automation cannot fully prove a runtime change, say so clearly and include the manual verification steps that are still needed.

## Documentation Rules

Update `README.md` when a user, packager, or script author would notice the change.

That includes changes to:

- setup or requirements
- config keys or examples
- CLI or `wlchroma-ctl` behavior
- runtime control behavior
- limitations, fallbacks, or compatibility notes

## Output Expectations

When submitting or summarizing changes:

- explain why the change exists
- list the commands that were run
- state what passed and what remains unverified
- mention any spec or README updates included in the diff

## Pull Request Hygiene

- Use the repo commit convention: `<type>(<scope>): <description>`.
- Keep PRs small enough to review quickly.
- Do not open cleanup-only PRs unless they are explicitly requested.
- If the repo is dirty, avoid touching unrelated files.
