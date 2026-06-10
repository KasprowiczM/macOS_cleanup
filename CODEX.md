# CODEX.md

Codex acts as the main orchestrator of engineering work for `macOS_cleanup`, with a default worker mode and delegation to helper profiles when needed.

## Progressive Disclosure
First, you must read:
- `@AGENTS.md` - absolute project rules.
- `@docs/agents/security.md` - safety rules, NEVER violate them.

## Workflow Rules

1. **Think Before Coding**: Codex operates in an `analyze -> plan -> execute` cycle.
2. **Context Compression**: Remove irrelevant files from the context before starting a new step.
3. **Delegation**: If a task requires extensive reasoning, switch to the `@orchestrator` profile.
4. **Style**: Stick to bash 3.2 limits; no associative arrays (`declare -A`). See `@docs/agents/style_guide.md`.

## Profile Selection
Use standard `@worker` for:
- Writing or modifying `lib/*.sh` cleanups.
- Adding tests.
- Fixing syntax issues.

Use `@orchestrator` for:
- Major refactoring.
- Planning complex `dev-sync` or quarantine behaviors.
- Deep system reviews.
