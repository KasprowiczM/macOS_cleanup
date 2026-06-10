# Dev Sync Quick Start

## TL;DR

```bash
# First time setup
bash dev-sync/provider_setup.sh

# Export private files to cloud
bash dev-sync-export.sh

# Import private files from cloud
bash dev-sync-import.sh

# Verify sync is correct
bash dev-sync-verify-full.sh

# Review provider cleanup candidates
bash dev-sync-prune-excluded.sh
```

## Supported Cloud Providers

- iCloud Drive
- Google Drive
- OneDrive
- Proton Drive
- Mega.nz
- rclone (S3, B2, Dropbox, etc.)
- Local/Custom folder

For space savings and safety, cleanup outputs, dependency folders, build outputs, caches, graphify outputs, key material, and external skill repos are excluded from provider sync.

## Setup (First Time)

```bash
bash dev-sync/provider_setup.sh
```

The wizard will:
1. Auto-detect installed cloud apps
2. Let you choose a provider
3. Ask for a project folder name
4. Save configuration to `.dev_sync_config.json`

## Export Private Files

```bash
# Preview (dry-run)
bash dev-sync-export.sh --dry-run

# Actually export
bash dev-sync-export.sh

# Show files being exported
bash dev-sync-export.sh --verbose
```

What gets exported:
- `.dev_sync_config.json`
- `.env`, `.env.local`, `.env.*.local`, `.dev.vars`, and `.dev.vars.*` files
- Config files in `.vscode/`, `.idea/`
- Any other untracked/ignored files matching `include_always` patterns

What doesn't get exported:
- `.git/` folder
- `logs/`, `reports/`, `graphify-out/`
- `node_modules/`, `.venv/`, `dist/`, `build/`
- `secrets/`, `.ssh/`, `*.pem`, `*.key`, certificate files
- `.claude/settings.local.json`, `.gemini/settings.local.json`
- `*.log`, `*.tmp`, `*.bak` files
- `.DS_Store` files

## Import Private Files

```bash
# Preview (dry-run)
bash dev-sync-import.sh --dry-run

# Actually import
bash dev-sync-import.sh

# Show files being imported
bash dev-sync-import.sh --verbose
```

Use this on a new Mac after cloning the repo.

## Verify Everything Works

```bash
# Quick git check
bash dev-sync-verify-git.sh

# Full verification
bash dev-sync-verify-full.sh

# Detailed output
bash dev-sync-verify-full.sh --verbose

# Check for stale/generated files already in cloud
bash dev-sync-prune-excluded.sh
```

## Logs

All operations create timestamped logs in `dev_sync_logs/`:

```bash
# View latest export log
cat dev_sync_logs/export_*.log | tail -1

# View latest import log
cat dev_sync_logs/import_*.log | tail -1

# View verification log
cat dev_sync_logs/verify_full_*.log | tail -1
```

## Configuration File

Location: `.dev_sync_config.json`

```json
{
  "project_name": "macOS_cleanup",
  "provider": "protondrive",
  "provider_path": "/Users/<USERNAME>/Library/CloudStorage/ProtonDrive-.../",
  "exclude_patterns": [...],
  "include_always": [...]
}
```

To change provider:
```bash
bash dev-sync/provider_setup.sh
```

## Common Tasks

### Switch Cloud Provider
```bash
bash dev-sync/provider_setup.sh
```

### Export after changing .env
```bash
bash dev-sync-export.sh
```

### Restore on New Mac
```bash
bash dev-sync/provider_setup.sh
bash dev-sync-import.sh
```

### Check What Would Be Synced
```bash
bash dev-sync-export.sh --dry-run --verbose
bash dev-sync-import.sh --dry-run --verbose
```

### Clean Bad Cloud Sync Safely
```bash
bash dev-sync-prune-excluded.sh --plan-out dev_sync_cleanup_plan.json
bash dev-sync-prune-excluded.sh --apply-plan dev_sync_cleanup_plan.json
bash dev-sync-verify-full.sh
bash dev-sync-purge-quarantine.sh --apply
```

### Check Proton Before Freeing Local Disk
```bash
bash dev-sync-proton-status.sh --full
```

### Debug Issues
```bash
# Check git state first
bash dev-sync-verify-git.sh

# Then full verification
bash dev-sync-verify-full.sh --verbose

# Check the detailed log
cat dev_sync_logs/verify_full_*.log
```

## Transport Method

Files are synced using the most efficient method:
- **rsync** (if installed) — fast incremental sync
- **Python shutil** (fallback) — slower but works anywhere
- **rclone copy** (for rclone provider) — network-aware

## File Organization

```
dev-sync/
├── dev_sync_core.py       # Core logic
├── dev_sync_export.py     # Export CLI
├── dev_sync_import.py     # Import CLI
├── dev_sync_verify_*.py   # Verification CLIs
├── dev_sync_prune_excluded.py
├── dev_sync_purge_quarantine.py
├── dev_sync_proton_status.py
├── provider_setup.sh      # Interactive setup
├── README.md              # Full documentation
└── QUICK_START.md         # This file
```

Root-level wrappers:
```
dev-sync-export.sh
dev-sync-import.sh
dev-sync-verify-full.sh
dev-sync-verify-git.sh
dev-sync-prune-excluded.sh
dev-sync-purge-quarantine.sh
dev-sync-proton-status.sh
```

## Help & Documentation

```bash
# Full documentation
cat dev-sync/README.md

# Config schema details
cat dev-sync/README.md | grep -A 50 "Configuration File"

# Operator guide
cat DEV_SCRIPTS_README.md
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Provider not available" | Run `bash dev-sync/provider_setup.sh` to configure |
| Cloud app not detected | Manually enter path in setup wizard |
| Permission denied on cloud folder | Check System Preferences for cloud app access |
| Git verification fails | Run `git status` and commit/push any changes |
| Files not syncing | Check logs: `cat dev_sync_logs/export_*.log` |
| Proton has old junk | Run `bash dev-sync-prune-excluded.sh --plan-out dev_sync_cleanup_plan.json` |
| rclone not found | Install: `brew install rclone` |
| rsync not found | Install: `brew install rsync` |

## Quick Reference

```bash
# Setup
bash dev-sync/provider_setup.sh          # Interactive provider selection

# Sync operations
bash dev-sync-export.sh                  # Export to cloud
bash dev-sync-import.sh                  # Import from cloud

# Verification
bash dev-sync-verify-git.sh              # Check git state
bash dev-sync-verify-full.sh             # Check git + cloud sync
bash dev-sync-prune-excluded.sh          # Plan stale/generated cloud cleanup
bash dev-sync-proton-status.sh --full    # Check Proton upload before offload

# Flags
--dry-run                                # Preview without writing
--verbose                                # Show detailed output
--help                                   # Show command help
```

For detailed information, see `dev-sync/README.md`
