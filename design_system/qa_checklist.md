# QA Checklist

Use this checklist to review any generated landing page before treating it as a
candidate design.

## P0 - Must Pass

- The first viewport explains what the product does.
- The first viewport makes clear that analysis is read-only.
- The page uses `Analyze`, `Plan`, and `Apply` consistently.
- The page uses `SAFE`, `REVIEW`, and `DANGEROUS` consistently.
- It does not imply one-click deletion of everything.
- It does not claim mail, keychains, browser profiles, documents, identity data,
  SSH/GPG keys, or signing certificates are auto-cleaned.
- It does not call quarantine a backup.
- It does not invent reclaimed-space metrics, customer logos, testimonials, or
  benchmarks.
- Primary CTA is visible and specific.
- Secondary CTA does not compete with the primary CTA.
- Text contrast meets WCAG AA.
- Status meaning is not color-only.
- Mobile has no horizontal scroll at 360px, 390px, and 430px widths.
- Tap targets are at least 44px where touch is expected.
- FAQ or objection handling answers the main safety concerns.
- No decorative controls, viewport selectors, theme knobs, or design metadata
  appear as product UI.

## P1 - Should Pass

- Product visual uses credible content: report, plan, terminal, risk table, or
  quarantine flow.
- Section order builds trust before breadth.
- Risk colors are used sparingly.
- Layout rhythm varies without becoming busy.
- Feature coverage distinguishes automatic safe cleanup from review-only
  guidance.
- Protected-path list is visible before the FAQ or repeated inside it.
- Quarantine and permanent purge are explained separately.
- Technical credibility includes Bash 3.2, macOS 10.15+, reports, plans,
  journals, and restore manifests.
- Buttons have hover, active, disabled, and focus states.
- FAQ accordion is keyboard accessible if implemented.
- Typography feels premium, not default-browser plain.
- Tables and matrices are readable on mobile.

## P2 - Polish

- The hero has one memorable product-led visual flourish.
- Motion improves perceived quality without slowing comprehension.
- Dark mode is considered if the generator supports it.
- Code snippets and paths use mono with tabular numerics.
- Final CTA restates the safest first action.
- Footer includes docs, safety model, repository, license, and contact links.

## Anti-Template Audit

Reject or revise if the generated page contains:

- Blue/purple gradient blobs.
- Neon glow or glassmorphism.
- Generic stock photography.
- Icon-in-colored-circle feature cards repeated across the page.
- Three identical 3-card grids in a row.
- "Unlock the future", "revolutionize", "empower", or "all-in-one solution".
- Fake dashboard screenshots with invented values.
- Low-contrast grey text.
- Overly soft visual treatments that make deletion feel casual.

## Acceptance Standard

The generated landing page is acceptable only if it feels:

- Trustworthy.
- Precise.
- Calm.
- Premium.
- Source-backed.
- Conversion-aware.
- Implementation-ready.

The page should make a skeptical technical user more willing to run a read-only
analysis because the safety boundaries are clear.

