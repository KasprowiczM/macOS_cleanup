# Landing Page Brief

## 1. Executive Design Direction

Create a premium minimalist landing page for `macOS Updates`, a safe macOS
cleanup and maintenance utility for developers, power users, and careful
operators who want to reclaim space without risking critical user data.

Primary page goal:

- Convert qualified visitors into first-run users or demo/evaluation leads.
- Build enough trust that a visitor is willing to run an analysis command.
- Make clear that analysis is read-only and cleanup requires explicit consent.

Primary CTA:

- `Run a safe analysis`
- Alternative: `Start with dry-run`

Secondary CTA:

- `See the safety model`
- Alternative: `Review the workflow`

First 5 to 10 seconds must communicate:

- This is not a one-click cleaner.
- It scans first, produces a plan, and applies only approved safe actions.
- Mail, keychains, browser profiles, documents, and identity data are protected.
- Quarantine and restore are part of the workflow where rollback is possible.

## 2. Positioning Framework

Business goal:

- Drive trust-based adoption of a technical macOS maintenance tool.

User intent:

- Understand whether the tool is safer and more transparent than commercial
  cleaner apps.
- Verify that it will not touch critical data.
- See enough implementation detail to trust the workflow.

Audience:

- macOS developers with large Xcode, Docker, npm, pip, Homebrew, simulator, and
  cache footprints.
- Technical operators maintaining personal or work machines.
- Power users skeptical of opaque cleanup apps.

Visitor objections:

- "Will this delete something important?"
- "Can I preview before applying?"
- "Can I roll back?"
- "Does it touch mail, passwords, browser profiles, or documents?"
- "Is this just another cleaner with marketing claims?"
- "Will it work with stock macOS bash?"

Core response:

- `Analyze -> Plan -> Apply` is explicit.
- `SAFE`, `REVIEW`, and `DANGEROUS` are visible risk classes.
- Default response is no action.
- `DANGEROUS` is blocked from automatic apply.
- Quarantine is rollback, not a backup.

## 3. Brand and Visual Strategy

The brand should feel like a shipped operator utility with a premium product
studio finish.

Visual principles:

- Lead with typography, spacing, and clarity.
- Use neutral surfaces and fine borders before color.
- Use the accent only for the primary CTA and one key state per viewport.
- Treat risk colors as semantic product language, not decoration.
- Prefer product UI, command snippets, report previews, and plan rows over
  abstract illustrations.

The page should never feel:

- Casual about deletion.
- Decorative for its own sake.
- Like a generic SaaS template.
- Like a system optimizer making unverifiable promises.

## 4. Landing Page Information Architecture

Recommended section order:

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

This order intentionally puts trust before breadth. The visitor should first
understand why the product is safe, then what it can clean.

## 5. Section-by-Section Specification

### Header

Purpose:

- Orient the user and expose the main conversion path.

Required elements:

- Product name: `macOS Updates`
- Nav links: `Safety`, `Workflow`, `Coverage`, `FAQ`
- Primary CTA: `Run a safe analysis`

Layout:

- Sticky optional, 64 to 72px tall.
- Fine bottom border.
- No oversized nav or account controls.

Mobile:

- Keep product name and CTA visible.
- Collapse secondary links if needed.

Avoid:

- Multiple competing CTA buttons.
- Marketing nav bloat.

### Hero

Purpose:

- Explain what the tool does and why it is safer.

Required elements:

- Eyebrow: `Analyze first. Apply only with consent.`
- Headline: outcome plus safety.
- Subheadline: one clear sentence about reports, plans, quarantine, and protected
  data.
- Primary CTA and secondary CTA.
- Product-led visual: plan table, terminal/report split, or risk summary.

Recommended copy direction:

- `Reclaim macOS space without guessing what is safe to delete.`

Visual treatment:

- Neutral background.
- Large left-aligned or centered headline.
- One precise product visual with real labels.

Mobile:

- Text first, product visual second.
- CTAs stack only if width requires it.

Avoid:

- Blobs, fake screenshots, neon terminal fantasy, one-click magic.

### Safety Proof Strip

Purpose:

- Quickly reduce fear.

Required elements:

- `Default no action`
- `Dry-run analysis`
- `Protected paths`
- `Quarantine restore`
- `Bash 3.2 compatible`

Layout:

- Compact horizontal strip on desktop.
- Two-column or single-column pills on mobile.

Avoid:

- Customer logos unless real.
- Fake metrics.

### Workflow: Analyze, Plan, Apply

Purpose:

- Teach the adoption path.

Required elements:

- Three steps with concise explanation.
- Show read-only vs destructive boundary.
- Include example commands where useful.

Copy:

- Analyze: read-only scan and report.
- Plan: candidates with risk, size, consequence, rollback.
- Apply: executes only approved scope through guardrails.

Visual:

- Horizontal stepper or vertical timeline.
- Use `Apply` as the only visually stronger step, but do not make it look
  automatic.

Mobile:

- Vertical step list.

Avoid:

- "Three easy steps to clean everything."

### Risk Model: SAFE, REVIEW, DANGEROUS

Purpose:

- Make the safety model memorable.

Required elements:

- Three risk cards or rows.
- Each card includes meaning, apply behavior, and example.

Recommended content:

- `SAFE`: rebuildable cache and temporary artifacts.
- `REVIEW`: useful candidates with context or cost.
- `DANGEROUS`: data, identity, profiles, backups, broad roots.

Visual:

- Use semantic colors only inside labels, small bars, or badges.
- Do not color entire large cards strongly.

Avoid:

- Reducing risk to vague low/medium/high without explanation.

### Protected Data Promise

Purpose:

- Answer the strongest objection.

Required elements:

- Explicit never-touch list.
- Mail, Keychain, browser profiles, Documents/Desktop, Photos/Music, SSH/GPG,
  signing certificates, quarantine root.
- Statement that parent-directory deletion cannot bypass protections.

Layout:

- Split section: promise copy plus structured protected-path list.

Avoid:

- "100% safe" language.
- Hiding this in FAQ only.

### Developer Cleanup Coverage

Purpose:

- Show value for the main audience.

Required elements:

- Xcode DerivedData.
- Simulators.
- npm, pip, Homebrew, Docker.
- Logs, caches, app leftovers, large installers.
- Time Machine and iOS backup handling as review-oriented, not automatic.

Visual:

- Dense capability matrix, not decorative feature cards.

Avoid:

- Claiming automatic cleanup for categories that require review.

### Quarantine and Restore

Purpose:

- Explain rollback honestly.

Required elements:

- Quarantine path concept.
- Restore manifest.
- Purge as separate deliberate action.
- Native commands without rollback labeled clearly.

Copy:

- "Quarantine is rollback, not backup."
- "Space is reclaimed after permanent mode or purge."

Avoid:

- Presenting quarantine as a full backup replacement.

### Technical Credibility

Purpose:

- Reassure technical users that the project is inspectable and predictable.

Required elements:

- Bash 3.2.
- macOS 10.15+.
- Modular `lib/`.
- YAML rules mapped to UX risk classes.
- Markdown reports, JSON plans, JSONL journals, TSV restore manifests.

Layout:

- Compact code/report module.

Avoid:

- Excessive implementation detail in the hero.

### FAQ

Purpose:

- Handle remaining objections.

Required questions:

- Does analyze delete anything?
- What does `--yes` approve?
- What is never touched?
- Can I restore quarantined files?
- Does quarantine free space immediately?
- What happens with browser or Mail data?
- Can developers run only one category?

### Final CTA

Purpose:

- Convert after trust is established.

Required elements:

- Headline restating safe first action.
- Primary CTA: `Run a safe analysis`.
- Secondary CTA: `Read the safety model`.
- Small reassurance: `Analyze is read-only. Apply requires consent.`

Avoid:

- Introducing new claims at the end.

### Footer

Purpose:

- Utility and credibility.

Required elements:

- Product links.
- Docs links.
- GitHub/repository link if available.
- License.
- Safety model link.

## 6. Visual Quality Bar

Generated pages should look:

- Calm and serious.
- Sparse but not empty.
- Dense where proof matters.
- Typographically confident.
- Highly readable at mobile widths.
- Built around product evidence, not decoration.

