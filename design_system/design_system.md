# macOS Updates Landing Page Design System

This is the canonical pasteable design-system brief for generating a landing
page. It is based on the repo docs and the root `DESIGN.md`; it does not define
new cleanup behavior.

## 1. Executive Design Direction

Create a professional, modern, minimalist landing page for `macOS Updates`, the
public-facing product name for this repo-backed macOS cleanup and maintenance
utility.

Positioning:

- For macOS developers, power users, and careful operators.
- Helps reclaim space from caches, logs, build artifacts, app leftovers, and
  known maintenance candidates.
- Differentiates through transparent safety, not aggressive automation.
- Uses `Analyze -> Plan -> Apply` as the core user journey.
- Uses `SAFE`, `REVIEW`, and `DANGEROUS` as visible risk language.

Primary goal:

- Get qualified visitors to run a read-only analysis or evaluate the workflow.

Primary CTA:

- `Run a safe analysis`

Secondary CTA:

- `See the safety model`

What the visitor must understand immediately:

- Analyze is read-only.
- Apply requires explicit approval.
- Dangerous data is blocked from automatic cleanup.
- Quarantine provides rollback for supported user-scope removals.
- The tool is inspectable through reports, plans, journals, and restore
  manifests.

## 2. Brand Personality

Adjectives:

- Precise
- Trustworthy
- Conservative
- Modern
- Calm
- Technical
- Premium
- Transparent

Voice:

- Clear over clever.
- Specific over broad.
- Evidence before claim.
- Direct but not alarmist.
- Human, practical, and technically literate.

The brand should feel like:

- A careful system operator.
- A well-built developer utility.
- A premium product studio interpretation of a safety-first CLI.

The brand should never feel like:

- A one-click cleaner.
- A gamified optimizer.
- A generic SaaS landing page.
- A tool that hides consequences behind marketing.

## 3. Art Direction

Use aesthetic territory, not imitation:

- Premium neutral software.
- Swiss-inspired information hierarchy.
- Product-led technical clarity.
- macOS-adjacent restraint.
- Operator dashboard precision.

Rationale:

This product sells trust. Trust comes from clear type, exact language, visible
boundaries, and source-backed product visuals. Decoration should never compete
with the safety model.

Hero visual direction:

- Use a credible plan/report visual, not abstract art.
- Show risk rows, commands, report files, protected paths, or quarantine flow.
- Keep text large enough to read in the design preview.

Avoid:

- Gradient blobs.
- Neon terminals.
- Fake dashboards.
- Generic device mockups.
- Stock photos of laptops or cleaning metaphors.

## 4. Full Design System

### Color

Use `design_system/tokens.css` as the source for implementation tokens.

Core strategy:

- Neutral surfaces carry most of the page.
- `--accent` is reserved for primary CTA and one active/proof moment.
- Risk colors are semantic and must be paired with labels.
- Do not flood entire sections with status color.

Primary tokens:

```css
--bg: oklch(98.5% 0.003 245);
--surface: oklch(100% 0 0);
--surface-muted: oklch(96.5% 0.006 245);
--fg: oklch(18% 0.018 245);
--muted: oklch(50% 0.014 245);
--border: oklch(88% 0.008 245);
--accent: oklch(54% 0.15 248);
--safe: oklch(56% 0.15 150);
--review: oklch(68% 0.14 78);
--dangerous: oklch(58% 0.18 28);
```

### Typography

Display:

- `SF Pro Display`, system sans.
- 600 to 700 weight.
- Tight but not compressed.

Body:

- `SF Pro Text`, system sans.
- 400 to 500 weight.
- 17 to 19px for primary body copy.

Mono:

- `SF Mono`, `JetBrains Mono`, `IBM Plex Mono`, ui-monospace.
- Use for commands, paths, report names, JSON/TSV labels, sizes, run IDs, and
  risk metadata.

Type scale:

- Hero: 56 to 84px desktop, 38 to 46px mobile.
- Page title: 44 to 60px.
- Section title: 32 to 44px.
- Subsection title: 20 to 26px.
- Body: 16 to 19px.
- Small: 13 to 15px.
- Caption/metadata: 12 to 13px.

### Spacing and Layout

Container:

- Standard: 1200px.
- Narrow text: 760 to 880px.
- Wide product visual: 1360px max.

Section rhythm:

- Hero: 96 to 140px top/bottom on desktop.
- Main sections: 80 to 128px.
- Compact proof strips: 32 to 56px.
- Mobile sections: 56 to 72px.

Grid:

- 12-column desktop.
- 6-column tablet.
- Single-column mobile.

Visual variety:

- Alternate hero, proof strip, split feature, dense matrix, stepper, FAQ, and
  final CTA.
- Avoid repeating identical three-card sections.

### Surfaces, Borders, Radius, Shadows

Surfaces:

- Use white or neutral muted panels.
- Cards are for actual repeated objects: risk classes, operations, categories,
  report files.

Borders:

- Prefer 1px hairline borders over shadows.
- Use stronger borders for active or critical states.

Radius:

- 6 to 8px for utility panels and controls.
- 10 to 12px for hero product modules.
- 999px only for compact pills.

Shadows:

- Minimal.
- Reserve for hero product visual, popovers, or modals.

### Motion

Use motion to clarify quality, not entertain.

- Hover transitions: 140 to 200ms.
- Reveal motion: opacity plus 8px vertical movement max.
- FAQ accordion: 180 to 240ms.
- No parallax.
- Respect `prefers-reduced-motion`.

### Iconography and Imagery

Icon style:

- Thin-line system icons only where they clarify.
- Do not put an icon beside every heading.

Imagery:

- Product UI previews, command modules, plan tables, report cards, risk rows.
- Labeled placeholders are acceptable when no screenshot exists.

Avoid:

- Generic AI illustrations.
- Decorative abstract UI that does not teach the product.

## 5. Landing Page Information Architecture

Section order:

1. Header
2. Hero
3. Safety proof strip
4. Workflow: Analyze, Plan, Apply
5. Risk model: SAFE, REVIEW, DANGEROUS
6. Protected data promise
7. Developer cleanup coverage
8. Quarantine and restore
9. Technical credibility
10. FAQ
11. Final CTA
12. Footer

The page should move from trust to workflow to capability to conversion.

## 6. Section-by-Section Specification

Use the full section guidance in `landing_page_brief.md`.

Non-negotiable section requirements:

- Hero must state read-only analysis before cleanup claims.
- Workflow must separate read-only and destructive phases.
- Risk model must explain apply behavior, not just labels.
- Protected data section must be visible before the FAQ.
- Developer coverage must distinguish `SAFE`, `REVIEW`, and report-only items.
- Quarantine section must state that quarantine is rollback, not backup.
- Final CTA must restate the safe first action.

## 7. Copy Framework

Use `copy_system.md` as the detailed copy source.

Preferred headline territory:

- `Reclaim macOS space without guessing what is safe to delete.`
- `Analyze first. Plan clearly. Apply only what you approve.`
- `Transparent macOS cleanup for people who read before they delete.`

Preferred proof copy:

- `Dry-run analysis before apply.`
- `Default unanswered prompts mean no action.`
- `DANGEROUS items are blocked from automatic apply.`
- `Reports, plans, journals, and restore manifests stay inspectable.`

Forbidden copy:

- "Guaranteed safe"
- "One-click clean"
- "Revolutionize"
- "Unlock the future"
- "All-in-one solution"
- Unsourced storage savings

## 8. UI Component Specification

Use `components.md` as the detailed component source.

Required component inventory:

- Navbar.
- Primary and secondary buttons.
- Risk pill.
- Workflow stepper.
- Product visual module.
- Safety proof strip.
- Coverage matrix.
- Protected data list.
- Quarantine/restore explainer.
- FAQ accordion.
- Footer.

Optional components:

- Announcement bar for a real release/status note.
- Lead capture form if the page goal is demo requests or signups.
- Testimonial/proof block only with real proof.

## 9. Final Prompt for Open Design / Claude Design

Use `generation_prompts.md`.

Recommended prompt:

- Start with the full direct-use prompt for a first serious generation pass.
- Use the compressed production prompt for quick iterations.
- Keep `tokens.css` open as the token reference.
- Keep `qa_checklist.md` open for review.

## 10. QA Checklist

Use `qa_checklist.md` as the acceptance gate.

Top failure conditions:

- The page looks like a generic SaaS template.
- It suggests automatic cleanup of protected data.
- It invents proof or storage metrics.
- It hides safety details below generic feature copy.
- It lacks a real mobile layout.
- It uses color-only risk communication.

Acceptance standard:

The page should make a skeptical technical user more willing to run a read-only
analysis because the safety boundaries are clear and the product looks credible.

