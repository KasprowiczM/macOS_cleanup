# Copy System

The landing page must sound conservative, specific, and technically credible.
The copy should make the safety model easier to understand, not hide it.

## Brand Voice

Use:

- Concrete nouns.
- Short cause-and-effect sentences.
- Exact product terms from the repo.
- Honest caveats.
- Calm confidence.

Avoid:

- "Unlock the future"
- "Revolutionize your Mac"
- "One-click optimization"
- "AI-powered cleaning"
- "All-in-one solution"
- "Guaranteed safe"
- "10x faster"
- "Free up gigabytes instantly" unless measured for the current user

## Canonical Vocabulary

Use consistently:

| Concept | Preferred copy |
|---|---|
| Read-only scan | `Analyze` |
| Candidate list | `Plan` |
| Execution | `Apply` |
| Low-risk item | `SAFE` |
| Human decision item | `REVIEW` |
| Blocked/protected item | `DANGEROUS` |
| Rollback holding area | `Quarantine` |
| Permanent deletion | `Purge` or `Permanent` |
| First action | `Run a safe analysis` |

Do not rename these concepts casually in headlines. They are the product model.

## Headline Formulas

Use one of these structures:

- `Reclaim macOS space without guessing what is safe to delete.`
- `A safer workflow for cleaning developer-heavy Macs.`
- `Analyze first. Plan clearly. Apply only what you approve.`
- `Transparent macOS cleanup for people who read before they delete.`

Avoid:

- `Clean your Mac in one click`
- `Optimize everything instantly`
- `The future of Mac maintenance`

## Subheadline Formulas

- `macOS Updates scans caches, logs, build artifacts, and known cleanup
  candidates, then produces a plan with risk, consequence, and rollback status
  before anything changes.`
- `Run a read-only analysis, review a structured plan, and apply only the safe
  scope you explicitly approve.`
- `Mail, keychains, browser profiles, documents, and identity data are protected
  by default.`

## CTA Rules

Primary CTAs:

- `Run a safe analysis`
- `Start with dry-run`
- `Generate a cleanup plan`

Secondary CTAs:

- `See the safety model`
- `Review protected paths`
- `Read the workflow`

CTA copy must describe the immediate action. Do not use vague labels like
`Get started` unless paired with a clearer sublabel.

## Proof Statement Formulas

Use implementation proof when external proof is unavailable:

- `Read-only analyze mode before apply.`
- `JSON plans, Markdown reports, JSONL journals, and restore manifests.`
- `DANGEROUS items are blocked from automatic apply.`
- `Default unanswered prompts mean no action.`
- `Bash 3.2 compatible for stock macOS environments.`

Do not invent:

- Customer counts.
- Storage savings.
- Benchmarks.
- Security claims beyond the documented guardrails.

## Feature Copy Pattern

Each feature should follow this shape:

1. Capability: what the product does.
2. Boundary: what it refuses to do.
3. Outcome: why the user should care.

Example:

- `Developer cache analysis`
- `Finds Xcode, simulator, npm, pip, Homebrew, and Docker cleanup candidates
  while keeping user data and credentials outside automatic apply.`

## Objection Handling

Use direct Q/A:

Question:

- `Does analyze delete anything?`

Answer:

- `No. Analyze is read-only. It can calculate sizes, detect apps, and write
  reports, but it does not move, delete, or modify user data.`

Question:

- `What does --yes approve?`

Answer:

- `Only low-risk SAFE behavior. REVIEW and DANGEROUS items still require explicit
  handling or are blocked from automatic apply.`

Question:

- `Can I restore quarantined files?`

Answer:

- `Yes, when the item was moved through safe_remove() into user-scope quarantine.
  Native commands and permanent mode are labeled separately because they do not
  have the same rollback path.`

## FAQ Starter Set

1. `Does the first command delete files?`
2. `What is the difference between SAFE and REVIEW?`
3. `What is never touched?`
4. `How does quarantine work?`
5. `When is space actually reclaimed?`
6. `What happens to browser and Mail data?`
7. `Can I run only developer cleanup?`
8. `What files are generated after a run?`

## Tone Guardrails

Every important claim should answer one of these:

- What happens?
- What will not happen?
- What evidence does the user see?
- What risk class is it?
- Can it be rolled back?
- What must the user approve?

If a sentence does not answer one of those, remove or rewrite it.

