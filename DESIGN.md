# macOS Cleanup Design System

This design system translates the repository's safety model into a reusable
product language for HTML prototypes, reports, docs, and future UI surfaces.
It is intentionally quiet, operator-focused, and explicit about risk.

Source documents:

- `docs/ux_dx_safety_model.md` for `analyze -> plan -> apply` and risk classes.
- `docs/agents/security.md` for non-negotiable safety language.
- `docs/rules_design.md` for YAML rule semantics.
- `README.md` for user-facing product positioning.

## Product Posture

macOS Cleanup should feel like a professional operations tool for careful
power users: transparent, fast to scan, conservative by default, and never
ambiguous about data risk.

Use this posture:

- Trust first: show what will happen before asking for action.
- Dense but readable: reports and tools should fit useful information on screen.
- One decision at a time: every destructive step has a clear label, consequence,
  rollback status, and default-no affordance.
- System-native: use macOS-adjacent neutrals, crisp borders, and restrained color.
- No spectacle: avoid decorative gradients, novelty illustrations, and fake
  performance metrics.

## Canonical Vocabulary

Use these terms consistently across UI, docs, reports, and prototypes.

| Concept | Use | Do not use |
|---|---|---|
| Scan phase | `Analyze` | `Clean now`, `Optimize` |
| Decision phase | `Plan` | `Preview deletion` |
| Execution phase | `Apply` | `Run magic`, `Fix all` |
| Low-risk candidate | `SAFE` | `Harmless`, `Guaranteed safe` |
| Human decision | `REVIEW` | `Maybe`, `Medium` without explanation |
| Blocked/protected | `DANGEROUS` | `Unsafe to delete automatically` only in long copy |
| Rollback holding area | `Quarantine` | `Backup` |
| Permanent deletion | `Purge` / `Permanent` | `Empty`, `Erase everything` |

Write in concrete cause-and-effect language:

- Good: "Removes Xcode DerivedData; projects rebuild on next compile."
- Good: "No rollback: this native command manages its own deletion."
- Avoid: "Frees lots of space safely."

## Color Tokens

Use OKLCH tokens in new HTML/CSS work. The palette is neutral first, with risk
colors carrying meaning. Do not flood whole pages with status colors.

```css
:root {
  --bg: oklch(98.5% 0.003 245);
  --surface: oklch(100% 0 0);
  --surface-raised: oklch(96.5% 0.006 245);
  --fg: oklch(18% 0.018 245);
  --muted: oklch(50% 0.014 245);
  --border: oklch(88% 0.008 245);
  --accent: oklch(54% 0.15 248);

  --safe: oklch(56% 0.15 150);
  --safe-bg: oklch(95% 0.035 150);
  --review: oklch(68% 0.14 78);
  --review-bg: oklch(96% 0.045 82);
  --dangerous: oklch(58% 0.18 28);
  --dangerous-bg: oklch(96% 0.04 28);
  --info: oklch(60% 0.13 235);
  --info-bg: oklch(95% 0.035 235);

  --font-display: -apple-system, BlinkMacSystemFont, "SF Pro Display",
    "Segoe UI", system-ui, sans-serif;
  --font-body: -apple-system, BlinkMacSystemFont, "SF Pro Text",
    "Segoe UI", system-ui, sans-serif;
  --font-mono: "SF Mono", "JetBrains Mono", "IBM Plex Mono", ui-monospace,
    Menlo, Consolas, monospace;
}
```

### Status Usage

| Status | Foreground | Background | Intended use |
|---|---|---|---|
| `SAFE` | `--safe` | `--safe-bg` | Auto-safe candidates, reversible cache, pass states |
| `REVIEW` | `--review` | `--review-bg` | Consent required, cost/latency tradeoffs, warnings |
| `DANGEROUS` | `--dangerous` | `--dangerous-bg` | Protected data, blocked operations, hard stops |
| `INFO` | `--info` | `--info-bg` | Read-only analysis, metadata, neutral guidance |

Risk color must be paired with the text label. Never rely on color alone.

## Typography

- Display: system display sans, 600-700 weight, no decorative type.
- Body: system text sans, 400-500 weight.
- Mono: paths, command names, IDs, bytes, timestamps, plan IDs, journal events.
- Use tabular numerics for byte counts, durations, counts, and run IDs.
- Prefer compact scale: large dashboard/report titles around 28-36px, section
  headings 18-24px, table text 13-15px.

## Layout Rules

Use a product-utility layout, not a landing-page layout.

- Primary shell: top status bar, left navigation or category rail, main work area.
- Main report width: `min(1180px, calc(100vw - 32px))`.
- Cards: only for repeated entities such as categories, operations, runs, and
  restore manifests. Do not put cards inside cards.
- Radius: 6-8px for panels and controls; 999px only for small pills.
- Borders: 1px hairlines using `--border`; shadows only for popovers/modals.
- Density: tables and lists should be scannable at operator speed.
- Empty states should say what is absent and whether that is good, blocked, or
  waiting for analysis.

## Core Components

### Risk Pill

Required fields:

- Label: `SAFE`, `REVIEW`, or `DANGEROUS`.
- Short reason: one sentence or tooltip.
- Optional rollback marker: `Quarantine`, `No rollback`, or `Report only`.

### Operation Row

Use for `plan.json`, reports, and future UI lists.

Required fields:

- Risk pill.
- Category.
- Path or native command.
- Estimated size with tabular numerics.
- Consequence.
- Rollback status.
- Decision state.

### Phase Stepper

The canonical sequence is:

1. `Analyze`
2. `Plan`
3. `Apply`
4. `Quarantine / Restore`

Only `Apply` and purge actions are destructive. The UI must visually separate
read-only phases from mutation phases.

### Consent Panel

Use for any action that may mutate disk state.

Required content:

- What will happen.
- What will not be touched.
- Whether rollback exists.
- The exact command or plan source.
- A default-no primary decision model for risky categories.

### Report Summary

Reports should lead with:

- Total reclaimable estimate.
- Count by `SAFE` / `REVIEW` / `DANGEROUS`.
- Largest categories.
- Generated files: report, plan, journal, restore manifest if present.
- Next safe command.

## Interaction Rules

- Default state is read-only analysis.
- Mutating actions require an explicit action label: `Apply SAFE items`,
  `Apply reviewed plan`, `Purge quarantine`.
- `DANGEROUS` items are blocked, not selectable for automatic apply.
- `REVIEW` items require a decision surface with consequences.
- `--yes` style automation language may only map to low-risk `SAFE` behavior.
- Native commands without quarantine rollback must be visibly marked `No rollback`.

## Content Rules

- Prefer "will" / "will not" over vague assurance.
- Use "quarantine" as rollback holding area, never as "backup".
- Never imply browser/profile/mail data is safe to remove automatically.
- Explain first-run costs: rebuild, re-download, re-index, slower first launch.
- Do not invent savings. If size is unknown, show `--` or `Unknown`.
- Keep path examples exact and monospace.

## Accessibility

- Minimum contrast: WCAG AA for text and controls.
- Status is conveyed by label plus color plus icon or shape when useful.
- Hit targets: at least 36px for dense desktop controls, 44px for touch surfaces.
- Focus states must be visible and not color-only.
- Tables need clear headers and non-wrapping numeric columns.

## Anti-Patterns

Avoid:

- Warm beige/pastel canvases that make a disk-cleanup tool feel casual.
- Full-screen gradients, ornamental blobs, and generic hero illustrations.
- "One-click clean everything" framing.
- Fake metrics such as "10x faster" or invented reclaimed storage.
- Hiding consequences in tooltips only.
- Using `SAFE` to mean no guardrails are needed.
- Calling quarantine a backup.

## Example UI Rhythm

For a future high-fidelity web prototype, use this section rhythm:

1. App shell with current run status and disk overview.
2. Category rail with counts and risk totals.
3. Operation table grouped by risk.
4. Plan detail drawer with consequence and rollback copy.
5. Consent panel for `Apply SAFE items`.
6. Quarantine / restore history.

The result should feel like a shipped admin utility: precise, calm, explicit,
and faster to evaluate than reading raw shell output.
