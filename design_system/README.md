# macOS Updates Design System

This folder adapts the root `DESIGN.md` into a full landing-page design system
for the macOS Updates project. The repository source material is still
`macOS_cleanup`: a safe, transparent macOS maintenance utility built around
analysis, planning, explicit consent, quarantine, restore, and protected paths.

Use this folder when generating a landing page in Open Design, Claude Design, or
another HTML design workflow. Do not use it as permission to change cleanup
behavior. The product promise must stay conservative and source-backed.

## Source Map

- `DESIGN.md`: canonical operator UI language, risk tokens, component posture.
- `README.md`: user-facing positioning, commands, safety model, categories.
- `docs/ux_dx_safety_model.md`: `analyze -> plan -> apply`, rollback, risk.
- `docs/agents/security.md`: non-negotiable safety boundaries.
- `docs/rules_design.md`: YAML safety semantics and rule taxonomy.
- Runtime architecture and reports flow: tracked `lib/` modules and `docs/agents/security.md`.

## Product Positioning

Working product name: `macOS Updates`

Repo-backed product truth:

- A professional macOS cleanup and maintenance utility.
- Built for power users, developers, and careful operators.
- Reads first, plans second, applies only with explicit consent.
- Uses `SAFE`, `REVIEW`, and `DANGEROUS` as visible risk language.
- Uses quarantine and restore manifests for rollback where possible.
- Never implies mail, keychains, browser profiles, documents, or identity data
  are safe to clean automatically.

## Design Direction

The visual system is neutral-led, typography-first, and operator-grade. It
should feel premium, precise, and calm, not playful, cozy, or loud.

Core traits:

- Professional
- Safety-first
- Transparent
- Minimal
- System-native
- Technical but readable
- Conversion-aware
- Trustworthy

Avoid:

- One-click-clean hype.
- Fake reclaimed-storage metrics.
- Gradient blobs, neon, glassmorphism, stock-photo maintenance metaphors.
- Generic SaaS feature cards with colored icon circles.
- Claims that override the repo safety model.

## Folder Contents

- `design_system.md`: canonical pasteable design-system brief.
- `landing_page_brief.md`: strategy, information architecture, section specs.
- `tokens.css`: CSS-ready visual tokens for landing pages and prototypes.
- `components.md`: reusable landing-page components and behavior rules.
- `copy_system.md`: product vocabulary, headline formulas, CTA rules, FAQ copy.
- `generation_prompts.md`: direct-use prompts for Open Design / Claude Design.
- `qa_checklist.md`: acceptance criteria for generated landing pages.

## Generator Contract

Any generated page should:

1. Explain the product in the first viewport.
2. Lead with safety, transparency, and control.
3. Use `Analyze`, `Plan`, and `Apply` as the core mental model.
4. Show `SAFE`, `REVIEW`, and `DANGEROUS` as visible product language.
5. Use restrained neutral surfaces, precise typography, and one blue accent.
6. Include real implementation cues: commands, reports, quarantine, restore.
7. Stay honest when proof or metrics are unavailable.

The generated page must not present destructive cleanup as effortless magic.
The trust mechanism is the product.
