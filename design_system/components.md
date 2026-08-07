# UI Component Specification

These components are for landing-page generation. They should express the
existing product safety model without turning the page into a dashboard.

## Announcement Bar

Purpose:

- Optional. Use only for real release status, audit note, or version milestone.

Visual rules:

- 36 to 44px tall.
- Muted surface, 1px border-bottom.
- Small mono label plus short body text.

Interaction:

- Dismissible only if implementing local state.

Avoid:

- Promotional urgency and fake scarcity.

## Navbar

Purpose:

- Orientation and conversion.

Priority:

- High.

Visual rules:

- 64 to 72px height.
- Transparent or `--surface` background.
- 1px bottom border.
- Product name in display font, 600 weight.

Spacing:

- Container max width 1200px.
- Horizontal gap 24 to 32px.

Interaction:

- Link hover changes text color, not background blocks.
- Primary CTA retains filled treatment.

Accessibility:

- Visible focus ring.
- Mobile menu button label must be accessible.

## Buttons

### Primary Button

Purpose:

- Main conversion action.

Visual rules:

- Filled `--accent`.
- `--accent-contrast` text.
- 44px minimum height.
- 8px radius.
- Medium weight.

Interaction:

- Hover darkens slightly or raises 1px.
- Active state compresses subtly.
- Disabled state must reduce opacity and remove hover.

### Secondary Button

Purpose:

- Lower-commitment path such as safety model or docs.

Visual rules:

- Surface background.
- 1px border.
- Foreground text.

### Text Link Button

Purpose:

- Inline secondary navigation.

Visual rules:

- No border.
- Underline on hover or focus.

Avoid:

- Loud gradients, glow, more than two CTA styles in one viewport.

## Risk Pill

Purpose:

- Teach and reinforce `SAFE`, `REVIEW`, `DANGEROUS`.

Visual rules:

- Small uppercase mono label.
- Rounded pill.
- Tint background plus semantic foreground.
- Always paired with text meaning nearby.

Spacing:

- Padding 4px 8px.

Accessibility:

- Risk meaning cannot rely on color alone.

## Workflow Stepper

Purpose:

- Explain `Analyze -> Plan -> Apply`.

Visual rules:

- Three steps with numeric labels.
- Read-only steps have neutral borders.
- `Apply` has a stronger caution treatment, not a celebratory treatment.

Interaction:

- On landing pages, static is acceptable.
- If interactive, use tabs with keyboard support.

Mobile:

- Stack vertically.

## Product Visual Module

Purpose:

- Replace generic hero art with credible product evidence.

Recommended variants:

- Plan table preview.
- Terminal command plus report excerpt.
- Risk summary with counts.
- Quarantine/restore flow diagram.

Visual rules:

- Use real labels from the repo.
- Use monospace for commands, paths, IDs, byte counts.
- Keep the module readable, not screenshot-tiny.

Avoid:

- Fake app screenshots with invented claims.
- Abstract blobs as the primary visual.

## Trust Strip

Purpose:

- Communicate safety guarantees quickly.

Items:

- `Dry-run first`
- `Default no`
- `Protected paths`
- `Quarantine restore`
- `Plan JSON`
- `Bash 3.2`

Visual rules:

- Small bordered chips or compact rows.
- No logos unless real.

## Feature / Coverage Matrix

Purpose:

- Show supported cleanup categories without overstating automation.

Rows:

- Trash
- System temp/logs
- User caches
- Developer caches
- App leftovers
- Time Machine/iOS backups
- Browser/Mail guidance

Columns:

- Category
- What is analyzed
- Risk default
- Apply behavior
- Rollback note

Visual rules:

- Table or comparison rows.
- No decorative icon card grid.

## Protected Data List

Purpose:

- Make hard safety boundaries visible.

Content:

- Mail stores.
- Keychain.
- Browser profiles.
- Documents/Desktop.
- Photos/Music/Movies.
- SSH/GPG and credential stores.
- Signing certificates.
- Quarantine root.

Visual rules:

- Use `DANGEROUS` or `Never auto-cleaned` labels carefully.
- Keep list scannable.

## Testimonial / Proof Block

Purpose:

- Add credibility when real proof exists.

Rules:

- Use real quotes only.
- If no customer proof exists, use implementation proof instead: reports,
  journals, restore manifests, protected path tests.

Avoid:

- Invented customer names, logos, or metrics.

## FAQ Accordion

Purpose:

- Objection handling.

Visual rules:

- 1px borders.
- No heavy card shadows.
- Question text 16 to 18px, 600 weight.

Interaction:

- Keyboard accessible.
- `aria-expanded` and `aria-controls` if implemented.
- One item open by default is acceptable.

## Email / Lead Capture Form

Purpose:

- Only if the page goal is lead generation.

Fields:

- Email.
- Optional role or use case.

Rules:

- Minimal field count.
- Visible labels.
- Inline validation.
- Privacy note: no vague reassurance.

Mobile:

- Inputs at least 44px high.

## Footer

Purpose:

- Utility and trust.

Content:

- Docs.
- Safety model.
- GitHub/repository.
- License.
- Contact.

Visual rules:

- Low contrast but accessible.
- Structured columns, not a large marketing block.

