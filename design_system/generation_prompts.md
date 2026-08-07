# Generation Prompts

Use these prompts in Open Design, Claude Design, or another HTML landing-page
generator. They instruct the tool to create a page, but this repository task did
not create the page itself.

## Full Direct-Use Prompt

Create a premium minimalist landing page for `macOS Updates`, a safe macOS
cleanup and maintenance utility based on the `macOS_cleanup` repository.

Product truth:

- It helps developers, power users, and careful operators analyze cleanup
  candidates before deleting anything.
- It is built around `Analyze -> Plan -> Apply`.
- `Analyze` is read-only.
- `Plan` produces Markdown reports, JSON plans, JSONL journals, and restore
  manifests when relevant.
- `Apply` executes only approved scope through guardrails.
- Risk language is `SAFE`, `REVIEW`, and `DANGEROUS`.
- Mail, keychains, browser profiles, documents, identity data, SSH/GPG keys,
  signing certificates, and broad user/system roots are never cleaned
  automatically.
- Quarantine provides rollback for supported user-scope removals, but it is not
  a backup and does not reclaim space until purge or permanent deletion.

Audience:

- macOS developers with large Xcode, simulator, Docker, npm, pip, and Homebrew
  footprints.
- Technical users who distrust opaque cleaner apps.
- Operators who want explicit reports, plans, and rollback semantics.

Primary page goal:

- Get qualified visitors to run a read-only analysis or request/evaluate the
  tool.

Primary CTA:

- `Run a safe analysis`

Secondary CTA:

- `See the safety model`

Visual direction:

- Neutral-led, typography-first, premium-minimal.
- Calm, precise, system-native, and trustworthy.
- Use strong hierarchy, generous whitespace, crisp 1px borders, restrained
  shadows, and one blue accent.
- Use semantic risk colors only for labels and small state moments.
- The page should feel like a top-tier product studio designed an operator tool,
  not like a generic SaaS template.

Use these tokens:

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

Typography:

- Display: `SF Pro Display`, system sans.
- Body: `SF Pro Text`, system sans.
- Mono: `SF Mono`, `JetBrains Mono`, `IBM Plex Mono`, ui-monospace.
- Use tabular numerics for sizes, counts, and run IDs.
- Hero text should be large and precise, not decorative.

Build this section order:

1. Header with concise nav and primary CTA.
2. Hero with an outcome-led headline, clear subheadline, primary and secondary
   CTA, proof line, and a product-led visual.
3. Safety proof strip: `Dry-run first`, `Default no`, `Protected paths`,
   `Quarantine restore`, `Plan JSON`, `Bash 3.2`.
4. Workflow section: `Analyze`, `Plan`, `Apply`, clearly separating read-only
   and destructive phases.
5. Risk model section: `SAFE`, `REVIEW`, `DANGEROUS`, each with meaning, apply
   behavior, and example.
6. Protected data section with the explicit never-touch list.
7. Developer cleanup coverage matrix for Xcode, simulators, npm, pip, Homebrew,
   Docker, logs, caches, app leftovers, Time Machine, and iOS backups.
8. Quarantine and restore section that explains rollback honestly.
9. Technical credibility section with Bash 3.2, macOS 10.15+, modular `lib/`,
   YAML rules, reports, plans, journals, and restore manifests.
10. FAQ with direct objection handling.
11. Final CTA.
12. Footer with docs, safety model, repo/license/contact links.

Copy style:

- Concise, concrete, technically credible.
- Prefer "will" and "will not" over vague reassurance.
- Use exact terms from the product model.
- Do not invent metrics, logos, testimonials, or benchmarks.

Avoid:

- One-click cleaner framing.
- Blue/purple gradient blobs.
- Neon glow.
- Glassmorphism.
- Stock photos.
- Fake dashboards.
- Colored icon-circle feature cards.
- Repeated generic 3-column sections.
- Phrases like "unlock the future", "revolutionize", "empower", "all-in-one",
  or "guaranteed safe".

Interaction:

- Subtle hover states only.
- FAQ accordion should be keyboard accessible.
- CTA focus states must be visible.
- Respect reduced motion.
- Do not add design controls, theme toggles, viewport selectors, or demo panels
  as product UI.

Responsive behavior:

- Desktop should feel spacious and editorially composed.
- Tablet should preserve hierarchy with fewer columns.
- Mobile should become a clear single-column flow with 44px+ tap targets, no
  horizontal scroll, readable text, and primary CTA visibility.

Quality bar:

- Agency-grade, launch-ready, coherent, accessible, implementation-ready, and
  source-backed.

## Compressed Production Prompt

Create a premium minimalist landing page for `macOS Updates`, a safe macOS
cleanup utility based on the `macOS_cleanup` repo. It is for macOS developers,
power users, and careful operators who want to reclaim space without risking
critical data. The core product model is `Analyze -> Plan -> Apply`: analyze is
read-only, plan shows candidates with risk/consequence/rollback, and apply runs
only approved scope through guardrails. Use visible risk language:
`SAFE`, `REVIEW`, `DANGEROUS`. Make clear that Mail, keychains, browser profiles,
documents, identity data, SSH/GPG keys, signing certificates, and broad roots are
never auto-cleaned. Quarantine is rollback, not backup.

Visual style: neutral-led, typography-first, premium-minimal, system-native,
calm, precise, and trustworthy. Use crisp 1px borders, restrained shadows, 8px
radii, strong spacing, system Apple typography, mono for commands/paths/stats,
one blue accent, and semantic risk colors only in labels/state moments. Avoid
gradient blobs, neon, glassmorphism, stock art, generic SaaS cards, fake metrics,
one-click cleaner hype, and phrases like "unlock", "revolutionize", "empower",
or "all-in-one".

Sections: header, hero, safety proof strip, workflow, risk model, protected data,
developer cleanup coverage matrix, quarantine/restore, technical credibility,
FAQ, final CTA, footer. Primary CTA: `Run a safe analysis`. Secondary CTA:
`See the safety model`. Copy must be concise, concrete, source-backed, and
conversion-aware. Mobile must be a clean single-column flow with no horizontal
scroll and 44px+ tap targets.

