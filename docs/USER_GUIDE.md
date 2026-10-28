# macOS Cleanup — Complete User & Operator Guide

`macOS_cleanup` is a safe, transparent space reclamation tool designed specifically for modern macOS (10.15+ through macOS 26+). It scans disposable development caches, log archives, temporary build artifacts, and package manager stores, moving eligible files into quarantine before permanent removal. It will **never touch** your personal documents, photos, mail accounts, keychains, browser profiles, password managers, or system critical files under any circumstances.

---

## 1. Before You Start

> ⚠️ **IMPORTANT SAFETY REQUIREMENT**
> 
> Quarantine is a temporary rollback buffer on disk — it is **not a backup** and reclaims no space until explicitly purged. Always verify you have an up-to-date Time Machine or external system backup before running any cleanup operations. If the script cannot verify a recent backup, it will display a warning before asking for confirmation.

---

## 2. The 4 Commands You Actually Need (In Order)

### Step 1: Read-Only Analysis (`--dry-run`)
Scan your disk safely without changing or deleting anything.

```bash
bash cleanup_all.sh --dry-run
```

**Real Output Example:**
```
═══════════════════════════════════════════════════
  macOS_cleanup v3.0.2 — System Analysis
═══════════════════════════════════════════════════

┌─ Disk Usage Overview ─────────────────────────────────────────────
│  Volume: /System/Volumes/Data
│  Size: 494.38 Gi  |  Used: 389.12 Gi  |  Free: 105.26 Gi (78% used)
└──────────────────────────────────────────────────────────────────

┌─ Safe User Cache ──────────────────────────────────────────────────
│  Size:       2.45 GB
│  Risk Level: SAFE
│  Consequences: Pliki zostaną bezpiecznie przeniesione do kwarantanny.
└──────────────────────────────────────────────────────────────────

┌─ Developer Caches (Xcode / DerivedData) ─────────────────────────
│  Size:       18.30 GB
│  Risk Level: REVIEW
│  Consequences: Pliki zostaną przeniesione do kwarantanny. Xcode zrekompiluje je przy następnym budowaniu.
└──────────────────────────────────────────────────────────────────

  FINAL SESSION SUMMARY
  ────────────────────────────────────────────────
  Mode:                       Analysis (dry-run) — nothing deleted
  To process (quarantined files free space only after --purge-quarantine):   25.76 GB
  Report File:                reports/report_2026-08-07_235500.txt
  Journal File:               reports/journal_2026-08-07_235500.jsonl
  ────────────────────────────────────────────────
```

---

### Step 2: Generate a Machine-Readable Plan (`plan`)
Create an explicit JSON execution plan file that specifies every path, action, and risk level.

```bash
bash cleanup_all.sh plan --out my_plan.json
```

**Real Output Example:**
```
  Plan generated successfully: my_plan.json
  Operations: 12 planned (SAFE: 4, REVIEW: 8, DANGEROUS: 0)
  Estimated size: 25.76 GB
```

---

### Step 3: Execute Safe Operations into Quarantine (`apply --from-plan`)
Executes ONLY `SAFE` risk operations into quarantine. `REVIEW` operations are skipped unless explicitly confirmed.

```bash
bash cleanup_all.sh apply --from-plan my_plan.json
```

**Real Output Example:**
```
▶ Applying plan: my_plan.json
  ✓ Quarantining: ~/.cache/yarn/v6  (1.2 GB) -> quarantine/2026-08-07_235800/items/...
  ✓ Executed plan command: npm cache clean --force
  ↷ Skipped (REVIEW risk required confirmation): Xcode DerivedData (18.30 GB)

  FINAL SESSION SUMMARY
  ────────────────────────────────────────────────
  Freed directly:      1.20 GB
  Quarantined:         1.25 GB (420 items)
  Purgeable (APFS):    2.45 GB   ← snapshot-retained; returns automatically
  Free now:            105.26 GB
  ────────────────────────────────────────────────
```

---

### Step 4: Purge Quarantine to Reclaim Disk Space (`--purge-quarantine`)
Permanently delete files stored in quarantine after verifying system stability.

```bash
# Preview what will be purged
bash cleanup_all.sh --purge-quarantine latest

# Apply permanent deletion
bash cleanup_all.sh --purge-quarantine latest --apply
```

**Real Output Example:**
```
▶ Purging quarantine run: 2026-08-07_235800
  ✓ Permanently removed quarantine items (1.25 GB)
  
  FINAL SESSION SUMMARY
  ────────────────────────────────────────────────
  Purged:              1.25 GB
  Report File:         reports/report_purge_2026-08-07_235900.txt
  ────────────────────────────────────────────────
```

---

## 3. Understanding Risk Levels

| Risk Level | Meaning | Examples | Automated Execution |
| :--- | :--- | :--- | :--- |
| **`SAFE`** | Reproducible temporary artifacts that are completely safe to remove. | App caches, completed downloading temp files, old `.dmg`/`.pkg` installers | Included in `--auto-safe` & `apply` |
| **`REVIEW`** | Valid data that can be regenerated but requires confirmation. | Build artifacts (DerivedData), CocoaPods, cargo caches, old iOS backups | Requires user confirmation or interactive prompt |
| **`DANGEROUS`** | Critical system or user identity files. | Keychains, Apple Mail, browser profiles, SSH/GPG keys, system paths | **NEVER executed or removed** |

---

## 4. Understanding Reclaimed Space & APFS Purgeable Space

When you delete files on macOS, `df -h` or Finder may not show an immediate increase in free space. This is expected APFS behavior:

1. **APFS Local Snapshots**: Time Machine creates local snapshots that retain deleted blocks until the snapshot expires or disk space is needed.
2. **Purgeable Space**: Space retained by APFS local snapshots is classified as **Purgeable**. macOS reclaims this space automatically within 24 hours or immediately when disk pressure increases.
3. **Checking APFS Purgeable Space**:
   ```bash
   diskutil info /System/Volumes/Data | grep -i "Purgeable"
   ```

---

## 5. Undo & Quarantine Restoration

If you ever need to restore files moved to quarantine:

```bash
# List all recorded quarantine runs
bash cleanup_all.sh --list-quarantine

# Restore the latest quarantine run
bash cleanup_all.sh --restore latest

# Restore a specific quarantine run by ID
bash cleanup_all.sh --restore 2026-08-07_235800
```

**Real Output Example:**
```
Restoring quarantine from latest run (run ID: 2026-08-07_235800): reports/restore_2026-08-07_235800.tsv
Other available quarantine runs:
  • 2026-08-07_210000
Hint: Target a specific run with: bash cleanup_all.sh --restore <run_id>
  ✓ Restored: ~/.cache/yarn/v6 -> ~/.cache/yarn/v6
```

> [!NOTE]
> Controlled native commands (such as `npm cache clean --force`, `brew cleanup`, or `docker system prune`) are executed via package managers and cannot be restored from quarantine.

---

## 6. Cleanup Categories

- **`user-caches`**: User application caches (`~/Library/Caches/*`). Safe to clear; apps recreate them as needed.
- **`system-logs`**: User diagnostic logs (`~/Library/Logs/*`). Purely informational diagnostic logs.
- **`dev`**: Developer build caches including Xcode `DerivedData`, `Archives`, CocoaPods, `cargo`, `pip`, `gradle`, and `npm`/`yarn`/`pnpm` caches.
- **`ios-simulators`**: Unavailable or orphaned iOS Simulator devices (`xcrun simctl delete unavailable`).
- **`device-support`**: Old Xcode iOS DeviceSupport debug symbols for older iOS versions.
- **`downloads`**: Old `.dmg` and `.pkg` installers in `~/Downloads` older than 30 days.
- **`trash`**: User Trash contents (`~/.Trash`).
- **`leftovers`**: Residual files left by uninstalled third-party applications.
- **Mail & Browsers**: Apple Mail, Thunderbird, Outlook, Chrome, Firefox, Safari, and Edge profiles are **strictly excluded**.

---

## 7. Excluding Custom Paths

Exclude specific directories or categories during any run:

```bash
# Exclude a path
bash cleanup_all.sh --dry-run --exclude "$HOME/Library/Caches/ImportantApp"

# Exclude a category
bash cleanup_all.sh --interactive --exclude-category dev
```

---

## 8. Developer Notes

- **npm / yarn / pnpm**: Cleaned via native commands (`npm cache clean --force`, `pnpm store prune`) or disposable cache paths (`~/.npm/_cacache`). Next build downloads dependencies if not in `node_modules`.
- **Xcode DerivedData**: Clearing DerivedData forces Xcode to recompile index files and build targets on the next build.
- **Cargo / Rust**: Clearing `~/.cargo/registry` requires `cargo build` to redownload crates.

---

## 9. Automation & Non-Interactive Mode

For headless servers, CI pipelines, or cron tasks:

```bash
# Non-interactive safe cleanup
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Machine-readable JSON output
bash cleanup_all.sh --dry-run --json
```

**Exit Codes:**
- `0`: Success / all operations completed cleanly.
- `1`: Non-fatal errors or skipped items.
- `2`: Invalid argument or missing configuration.
- `99`: Critical path protection violation (script aborted safely).

---

## 10. Troubleshooting FAQ

1. **"I ran cleanup and `df -h` didn't change!"**
   Deleted files are held in APFS local snapshots as **Purgeable space**. Check with `diskutil info /System/Volumes/Data | grep -i Purgeable`. macOS reclaims it automatically.
2. **"Why was Xcode DerivedData skipped during `--auto-safe`?"**
   DerivedData is classified as `REVIEW` risk to prevent unexpected rebuild delays. Run with `--interactive` or include category `dev` explicitly.
3. **"How do I clean quarantine files to regain space immediately?"**
   Run `bash cleanup_all.sh --purge-quarantine latest --apply`.
4. **"Can I restore files after `--purge-quarantine`?"**
   No. Purging permanently deletes items from disk.
5. **"Does this script ever run `sudo` or modify root system files?"**
   No. privileged `sudo` execution was permanently removed in v3.0.0. The script operates entirely within user permissions.

---

## 11. What is NEVER Touched (`NEVER_TOUCH_PATHS`)

The script strictly enforces non-negotiable protections for the following paths:

- `~/Library/Mail`
- `~/Library/Containers/com.apple.mail`
- `~/Library/Keychains`
- `~/Library/Application Support/Google/Chrome`
- `~/Library/Application Support/Firefox`
- `~/Library/Safari`
- `~/Library/Application Support/1Password`
- `~/Library/Application Support/Bitwarden`
- `~/Documents`
- `~/Desktop`
- `~/Pictures`
- `~/Music`
- `~/Developer`
- `~/.ssh`
- `~/.gnupg`
- `~/.aws`
- `/System`
- `/Library`
- `/usr`
- `/bin`
- `/sbin`
