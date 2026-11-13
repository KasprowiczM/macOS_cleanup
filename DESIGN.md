# macOS Cleanup Design System

This system describes two related surfaces: the editorial website and the command-line cleanup workflow. The website introduces the project; the CLI remains the source of truth for safety, risk, and actions.

Sources: [`docs/ux_dx_safety_model.md`](docs/ux_dx_safety_model.md), [`docs/agents/security.md`](docs/agents/security.md), [`docs/rules_design.md`](docs/rules_design.md), [`README.md`](README.md), and [`docs/BRANDING.md`](docs/BRANDING.md).

## Product posture

The website uses a warm, image-led editorial story around “Same Mac. Fresh start.” It can feel human and optimistic while remaining specific about what the tool does. Do not use invented output, performance figures, or promises that cleanup will recover a particular amount of space. Any terminal scene is illustrative and must be labeled as a demo.

The CLI and reports prioritize operational clarity: show what will happen before asking for action, make consequences and rollback status easy to scan, and use a default-no consent model. Each destructive action needs an explicit label and the exact command or plan source.

## Canonical vocabulary

| Concept | Use | Avoid |
|---|---|---|
| Scan phase | `Analyze` | `Clean now`, `Optimize` |
| Decision phase | `Plan` | `Preview deletion` |
| Execution phase | `Apply` | `Run magic`, `Fix all` |
| Low-risk candidate | `SAFE` | `Harmless`, `Guaranteed safe` |
| Human decision | `REVIEW` | `Maybe`, unexplained `Medium` |
| Blocked/protected | `DANGEROUS` | Vague “unsafe” without reason |
| Rollback holding area | `Quarantine` | `Backup` |
| Permanent deletion | `Purge` / `Permanent` | `Empty`, `Erase everything` |

Use cause-and-effect language: “Removes Xcode DerivedData; projects rebuild on next compile.” Avoid blanket assurances such as “Frees lots of space safely.” Quarantine moves free **0 bytes** on APFS until purged; local snapshots may retain purged blocks as Purgeable, and macOS controls when they are reclaimed.

## Brand palette

The website brand uses these colors as restrained editorial accents, with bone and charcoal doing most of the work:

| Token | Color | Use |
|---|---|---|
| Charcoal | `#141311` | Dark backgrounds and primary ink |
| Bone | `#EEE9DF` | Light page backgrounds |
| Coral | `#ED826D` | Warm editorial accent |
| Amber | `#F2AD5F` | Secondary warmth and highlights |
| Jade | `#91D5AB` | Brand green and positive product details |

Keep operational risk semantics distinct from the editorial palette. Use jade/green for `SAFE`, yellow for `REVIEW`, and red (for example, `#FFB5AB`) for `DANGEROUS`; always pair color with a text label and never rely on color alone. Use these status colors in reports and action surfaces, not as decorative page fills.

## Typography and layout

- Website: editorial display typography, generous spacing, image-led sections, and restrained motion.
- CLI/report: system sans for labels and explanations; monospace for paths, command names, IDs, bytes, timestamps, and journal events.
- Use tabular numerals for measurements and counts.
- Reports should prioritize scannable lists and tables over decorative cards. Repeated entities such as operations, categories, and restore manifests may use compact bordered panels.
- Mobile layouts must preserve complete imagery and readable text; avoid cropping away the product being described.

## Risk and consent components

A risk item should include its label (`SAFE`, `REVIEW`, or `DANGEROUS`), a short reason, consequence, and rollback status (`Quarantine`, `No rollback`, or `Report only`). `DANGEROUS` items are blocked from automatic apply. `REVIEW` items require a decision surface with consequences. Automation confirmation such as `--yes` applies only to `SAFE` risk categories.

The canonical flow is `Analyze` → `Plan` → `Apply` → `Quarantine / Restore`. Keep read-only phases visually distinct from mutation and purge actions. Never call quarantine a backup or imply that it itself frees disk space.

## Accessibility and content rules

- Meet WCAG AA contrast for text and controls.
- Provide visible keyboard focus and touch targets of at least 44px.
- Pair status colors with clear labels and, where helpful, an icon or shape.
- Explain first-run costs such as rebuilds, downloads, re-indexing, or slower first launches.
- If a size is unknown, show `Unknown`; do not invent savings.
- Keep paths and commands exact and monospace.
