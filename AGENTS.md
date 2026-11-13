# AGENTS.md

## GitHub Actions budget guardrail

This repository is owned by the `KasprowiczM` GitHub Free account. Private repositories share a hard allowance of 2,000 GitHub Actions minutes per month.

- Do not add, enable, or broaden scheduled workflows without the user's explicit approval.
- Default to `ubuntu-latest`; use macOS, Windows, or larger runners only when technically required and explicitly approved.
- Expensive platform-specific jobs should be manual or release-only, not triggered by every branch push.
- Restrict push/PR triggers by branch and path, add `concurrency` with cancellation, and set `timeout-minutes` on every job.
- Before changing Actions, estimate the monthly run count and minute impact. Do not change billing or spending limits without explicit approval.
- Public-repository standard runners may be free, but the same anti-waste rules still apply.


Project Goal: safe and predictable macOS cleanup without the risk of losing critical user data.

Stack: bash 3.2, macOS 10.15+, modular scripts in `lib/`.

## Minimum workflow

```bash
bash -n cleanup_all.sh lib/*.sh config/*.sh
/bin/bash tests/run_all.sh
bash cleanup_all.sh --dry-run
bash cleanup_all.sh --dry-run --category dev
python3 -m unittest tests/test_dev_sync_safety.py
```

## Non-negotiable Rule

PLANNING RULE (NON-NEGOTIABLE): Do not make any changes or write code until you have thoroughly explored the codebase and have at least 95% confidence in what you need to build; verify assumptions repeatedly before implementation.

## Progressive Disclosure

- `@CODEX.md` - Codex workflow rules and orchestrator/advisor/worker profiles.
- `@CLAUDE.md` - short index for working in the Claude environment.
- `@docs/agents/style_guide.md` - bash 3.2 conventions and `analyze_X` / `clean_X` patterns.
- `@docs/agents/testing_rules.md` - validation, dry-run, tests, and pre-merge checks.
- `@docs/agents/security.md` - security policy, `safe_remove()` and protected paths.
- `@docs/agents/handoff.md` - handing off work state and context compression.
- `@DEV_SCRIPTS_README.md` - operator guide for `dev-sync/`.
- `@DESIGN.md` - UX/UI design system for reports, prototypes, and future product surfaces.
- Generated project maps and machine baselines are local, ignored artifacts; use tracked source and tests as the public contract.
- `@docs/codex/profiles.md` - mapping of Codex model profiles (default/orchestrator/advisor/workers).
- `@docs/codex/context_controls.md` - context limits, logs, and compression rules.
- `@docs/codex/mcp_skills_policy.md` - policy for disabling MCP and skills for this repo.
