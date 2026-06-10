[🇺🇸 EN](user_guide.md) | [🇵🇱 PL](user_guide.pl.md) | [🇪🇸 ES](user_guide.es.md) | [🇫🇷 FR](user_guide.fr.md) | [🇩🇪 DE](user_guide.de.md) | [🇮🇹 IT](user_guide.it.md) | [🇵🇹 PT](user_guide.pt.md)

---

# macOS Cleanup — User Guide

This document assumes you do not need to know the `~/Library` structure or how caches work. The goal is to safely reclaim space without deleting emails, passwords, documents, browser profiles, projects, and application settings.

## The Golden Rule

Do not run the cleanup "blindly". Always do an analysis first:

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

This does not delete anything. The script will show:

- how much space can potentially be reclaimed,
- which items are `SAFE`,
- which items require `REVIEW`,
- which items are `DANGEROUS` and will not be automatically deleted.

## Risk Classes

| Class | Meaning | What the script does |
|-------|------------|----------------|
| `SAFE` | Recreatable data: app caches, build caches, old logs, tmp. | Can be deleted in `auto-safe` or executed from a plan. Defaults to quarantine for user files. |
| `REVIEW` | Space can be reclaimed, but there might be a cost: redownloading, slower startup, loss of diagnostic logs, emulator state. | Shows up in the plan. Not deleted automatically without a conscious decision. |
| `DANGEROUS` | Mail, browser profiles, passwords, documents, settings, active application data. | Only reports or blocks. Never deletes automatically. |

If you do not understand an item in the report, treat it as `REVIEW` or `DANGEROUS`.

## Backup and Quarantine

Real cleanup requires a fresh Time Machine backup. If the script cannot verify it, the cleanup will be blocked. You can force execution via:

```bash
bash cleanup_all.sh --auto-safe --allow-no-backup
```

Use this only if you consciously accept the risk.

Quarantine does not free up space immediately. By default, user files go to:

```text
~/Library/Application Support/macOS_cleanup/quarantine/<run_id>/
```

You will reclaim space only via `--permanent` or a subsequent purge:

```bash
bash cleanup_all.sh --purge-quarantine latest --apply
```

Restore:

```bash
bash cleanup_all.sh --restore latest
```

## Safest Workflow

### 1. Analysis

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

Read the report in `reports/report_*.md`.

### 2. JSON Plan

```bash
bash cleanup_all.sh plan --non-interactive --no-color
```

The plan saves to `reports/plan_*.json`. Each operation has an `id`, `risk`, `path`, `description`, and `recommendation`.

### 3. Safest Cleanup

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes
```

This only cleans explicitly known `SAFE` app caches. If there is no verified backup:

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes --allow-no-backup
```

### 4. Interactive Review for Larger Items

```bash
bash cleanup_all.sh --interactive
```

The script will show the category, size, consequences, and ask. The default answer is always `no`.

## What can be deleted without major consequences

The following items are usually `SAFE`, but might still cause a slower first app startup:

- Slack/Teams/Discord cache: the app will recreate web assets and thumbnails.
- VS Code/Cursor `Cache` and `Code Cache`: the editor will rebuild the cache; projects and settings remain.
- Standard Spotify `Cache`: music/podcasts will redownload.
- Zoom cache: does not delete recordings from `Documents/Zoom`.
- Xcode DerivedData: Xcode will rebuild projects from scratch.
- npm/pnpm/yarn/pip/Homebrew cache: dependencies will redownload.
- old logs: you lose diagnostic history, but not app data.
- old `/tmp` files: temporary, macOS usually cleans these itself.

## What Requires Analysis

### General `~/Library/Caches`

The script shows top-level `~/Library/Caches` items as `REVIEW`, because not all caches are cheap to recreate. Some apps keep large offline data, maps, media, AI models, or working caches there.

What to check:

- do you recognize the app by its folder name,
- does the app have offline data,
- do you accept redownloading gigabytes of data,
- are you not currently working offline.

### JetBrains

JetBrains cache can be large. Deletion does not erase projects, but the IDE will rebuild its indexes. This can take a long time and strain the CPU. Delete only when you have time for re-indexing.

### Adobe Media Cache

Does not delete source projects or media, but Premiere/After Effects might need to regenerate previews, conform audio/video, and caches. Delete only if you have the original media and accept a longer first project open.

### Figma

Cache is usually recreatable, but can affect reopening large files and offline work. Prefer review.

### Spotify PersistentCache

Can mean larger streaming/offline data. Deletion might force redownloads. The regular `Spotify Cache` is safer than `PersistentCache`.

### Xcode Device Support

These are debugging symbols for iOS/watchOS/tvOS devices. Xcode will redownload them when you connect a device with a given OS version. Delete only if you don't debug old devices or have time and internet.

### Xcode Archives

`.xcarchive` archives might be needed for the App Store, crash symbolication, and recreating builds. The script only reports them. Delete manually from Xcode Organizer after checking.

### Docker

`docker system prune -f` deletes images, stopped containers, networks, and build caches. It does not delete volumes, but stopped containers might contain state you haven't moved to a volume yet. Check:

```bash
docker ps -a
docker system df
```

### Android AVD

Android emulators can contain local test app states. Delete via Android Studio Device Manager, not via manual `rm` if you are unsure.

### Maven `~/.m2/repository`

Might contain locally built artifacts not available on the internet. The script treats this as review-only.

### iOS Backups

These are iPhone/iPad copies. Delete only if you have a recent iCloud backup or a new Finder backup.

### Time Machine local snapshots

macOS deletes these automatically when it needs space. Manual cleanup only makes sense if you understand you are losing local restore points.

## What the Script Does NOT Delete Automatically

### Apple Mail

`~/Library/Mail` and `~/Library/Containers/com.apple.mail` can contain messages, attachments, POP accounts, indexes, and local archives. The script only shows sizes and the largest areas.

Safe actions:

- in Mail.app, delete large messages,
- empty Trash and Junk in Mail.app,
- check attachments,
- export local mailboxes before manual intervention.

### Browsers

Chrome/Firefox/Safari/Edge/Brave profiles contain cookies, sessions, passwords, history, bookmarks, and extensions. The script does not delete them.

Clear site data via UI:

- Safari: Settings -> Privacy -> Manage Website Data.
- Chrome/Brave/Edge: `chrome://settings/clearBrowserData`.
- Firefox: Settings -> Privacy & Security -> Cookies and Site Data.

Deleting cookies might log you out of websites.

### Application Support and Preferences

`~/Library/Application Support` and `~/Library/Preferences` often contain databases, settings, licenses, local projects, and configurations. The script does not delete active application data. Leftovers from uninstalled apps are only reported.

## How to Read `plan.json`

Example:

```json
{
  "id": "op-0007",
  "category": "app-caches",
  "risk": "SAFE",
  "action": "remove_path",
  "path": "/Users/me/Library/Caches/com.spotify.client",
  "estimated_bytes": 532000000,
  "description": "Spotify cache: streaming cache muzyki/podcastów.",
  "recommendation": "SAFE: można usunąć przez auto-safe..."
}
```

Interpretation:

- `SAFE`: can be executed via `apply --from-plan`.
- `REVIEW`: requires a manual decision.
- `DANGEROUS`: will not be executed.
- `native_command`: the script will run a tool like `brew cleanup`; usually without quarantine rollback.
- `report_only`: information only, no deletion.

## Example Decisions

| Situation | Decision |
|----------|---------|
| You want to quickly reclaim some space without risk | `--auto-safe` |
| You have a lot of npm/pnpm cache and internet | clean the `dev` category after review |
| You have a large Chrome/Firefox profile | do not delete manually, use the browser UI |
| Large `~/Library/Mail` | clean from Mail.app, not via script |
| Large `Xcode Archives` | check Xcode Organizer |
| No Time Machine backup | do not do a real apply unless you consciously use `--allow-no-backup` |

## Handy Commands

```bash
# Analyze everything
bash cleanup_all.sh --dry-run --non-interactive --no-color

# JSON Plan
bash cleanup_all.sh plan --non-interactive --no-color

# Only developer cache
bash cleanup_all.sh --dry-run --category dev --non-interactive --no-color

# Safest cleanup
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Interactively, with full questions
bash cleanup_all.sh --interactive

# Simulate plan execution
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run --non-interactive --no-color

# Restore from quarantine
bash cleanup_all.sh --restore latest

# Free up space from quarantine after verification
bash cleanup_all.sh --purge-quarantine latest --apply
```

## When to Abort

Abort and do not confirm cleanup if:

- you do not have a backup,
- you do not understand the path,
- it relates to mail, browsers, passwords, documents, or settings,
- you are in the middle of diagnosing a crash and need logs,
- the app has offline data you do not want to redownload.

Safe cleaning is about reclaiming space from recreatable data, not deleting everything that is large.
