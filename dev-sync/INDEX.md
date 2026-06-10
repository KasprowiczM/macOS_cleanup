# Dev Sync System — File Index

This directory contains the complete dev-sync system for managing private project files across multiple cloud storage providers.

## Quick Navigation

### For First-Time Users
1. Start here: [QUICK_START.md](QUICK_START.md) — 5-minute setup guide
2. Run the wizard: `bash provider_setup.sh`
3. Then see [README.md](README.md) for full documentation

### For Developers
1. Architecture: See [README.md](README.md#architecture)
2. Core code: [dev_sync_core.py](dev_sync_core.py)
3. Operator guide: [../DEV_SCRIPTS_README.md](../DEV_SCRIPTS_README.md)

### Reference Materials
- Configuration details: [README.md](README.md#configuration-file)
- Troubleshooting: [README.md](README.md#troubleshooting)
- Command reference: [README.md](README.md#commands-reference)

## Files in This Directory

### Documentation

| File | Purpose | Audience |
|------|---------|----------|
| [QUICK_START.md](QUICK_START.md) | 5-minute quick start guide | Users - start here! |
| [README.md](README.md) | Complete documentation | Everyone |
| [INDEX.md](INDEX.md) | This file - navigation guide | Everyone |

### Core Implementation

| File | Lines | Purpose |
|------|-------|---------|
| [dev_sync_core.py](dev_sync_core.py) | 680 | Main logic: providers, config, sync operations |
| [dev_sync_export.py](dev_sync_export.py) | 40 | CLI for exporting files to cloud |
| [dev_sync_import.py](dev_sync_import.py) | 40 | CLI for importing files from cloud |
| [dev_sync_verify_full.py](dev_sync_verify_full.py) | 140 | CLI for full verification |
| [dev_sync_verify_git.py](dev_sync_verify_git.py) | 40 | CLI for git state verification |
| [dev_sync_prune_excluded.py](dev_sync_prune_excluded.py) | - | Plan/quarantine stale or generated provider files |
| [dev_sync_purge_quarantine.py](dev_sync_purge_quarantine.py) | - | Permanently delete reviewed quarantine |
| [dev_sync_proton_status.py](dev_sync_proton_status.py) | - | Check Proton File Provider upload/offload readiness |
| [provider_setup.sh](provider_setup.sh) | 420 | Interactive setup wizard (bash 3.2+) |
| [__init__.py](__init__.py) | 2 | Python package marker |

## Usage Commands

### First Setup
```bash
bash provider_setup.sh
```

### Export Private Files
```bash
bash dev-sync-export.sh                # Export to cloud
bash dev-sync-export.sh --dry-run      # Preview
bash dev-sync-export.sh --verbose      # Show files
```

### Import Private Files
```bash
bash dev-sync-import.sh                # Import from cloud
bash dev-sync-import.sh --dry-run      # Preview
bash dev-sync-import.sh --verbose      # Show files
```

### Verification
```bash
bash dev-sync-verify-git.sh            # Check git state
bash dev-sync-verify-full.sh           # Check git + cloud
bash dev-sync-verify-full.sh --verbose # Detailed report
bash dev-sync-prune-excluded.sh        # Dry-run cleanup candidate report
bash dev-sync-proton-status.sh --full  # Proton upload/offload readiness
```

## Supported Cloud Providers

- **iCloud Drive** — Mac native cloud storage
- **Google Drive** — Google's cloud storage (via Google Drive app)
- **OneDrive** — Microsoft's cloud storage
- **Proton Drive** — Privacy-focused cloud storage
- **Mega.nz** — MEGAsync app or rclone
- **rclone** — Network remotes (S3, B2, Dropbox, etc.)
- **Local** — Any local folder

## Configuration

Configuration file: `.dev_sync_config.json` in project root

```json
{
  "project_name": "macOS_cleanup",
  "provider": "protondrive",
  "provider_path": "/path/to/cloud/mount",
  "exclude_patterns": [...],
  "include_always": [...]
}
```

Edit with setup wizard: `bash provider_setup.sh`

## Logs

All operations create timestamped logs:
- Location: `dev_sync_logs/`
- Files: `export_*.log`, `import_*.log`, `verify_full_*.log`
- Contains: file lists, operation details, transport method

Example:
```bash
cat dev_sync_logs/export_20260331_124530.log
```

## Architecture Overview

```
CloudProvider (abstract base)
├── LocalFileSystemProvider
│   ├── iCloud
│   ├── Google Drive
│   ├── OneDrive
│   ├── Proton Drive
│   ├── Mega.nz
│   └── Local/Custom
└── RCloneProvider
    ├── S3
    ├── B2
    ├── Dropbox
    └── Any rclone remote
```

Transport methods:
1. **rsync** (if available) — Fast incremental
2. **Python shutil** (fallback) — Universal
3. **rclone copy** (for rclone provider) — Network-aware

Exports to local filesystem providers also write `.dev_sync_manifest.json` into the provider mirror. Imports prefer that manifest so stale files from older exports are not restored.

## Common Tasks

### Switch Cloud Provider
```bash
bash provider_setup.sh
```

### New Mac: Restore Private Files
```bash
bash provider_setup.sh        # Configure provider
bash dev-sync-import.sh       # Import files
```

### After Changing .env
```bash
bash dev-sync-export.sh
```

### Confirm Cleanup Outputs Are Excluded
```bash
bash dev-sync-export.sh --dry-run --verbose
```

The export list should not include `logs/`, `reports/`, `graphify-out/`, key material, or machine-local agent settings.

### Check Sync Status
```bash
bash dev-sync-verify-full.sh --verbose
```

### Clean stale/generated provider files
```bash
bash dev-sync-prune-excluded.sh --plan-out dev_sync_cleanup_plan.json
bash dev-sync-prune-excluded.sh --apply-plan dev_sync_cleanup_plan.json
bash dev-sync-purge-quarantine.sh --apply
```

### Debug Issues
```bash
bash dev-sync-verify-git.sh         # Check git state first
bash dev-sync-verify-full.sh        # Full verification
cat dev_sync_logs/verify_full_*.log # Check logs
```

## Key Concepts

### Export
Copies untracked/ignored files (`.env`, config) to cloud storage.
- Source: Local repository (untracked + ignored files)
- Destination: Cloud provider's `project_name` folder
- Filters: Applies `exclude_patterns` and `include_always`

### Import
Copies private files from cloud back to local repository.
- Source: Cloud provider's `project_name` folder
- Destination: Local repository
- Use on new machines to restore private files

### Verification
Checks that all files are properly synced.
- Git verification: Clean working tree, upstream set
- Full verification: Git state + cloud overlay files
- Report: Lists orphan files, missing files, stale files

## Backward Compatibility

Old `.dev_sync_config.json` files with only `proton_project_root` still work.
The system automatically migrates to the new schema.

```bash
# Old format still works
{
  "project_name": "macOS_cleanup",
  "proton_project_root": "/path/to/folder"
}

# Gets converted to new format on-the-fly
{
  "provider": "protondrive",
  "provider_path": "/path/to/folder"
}
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Provider not detected | Run `bash provider_setup.sh` and enter path manually |
| Permission denied | Check System Preferences > Cloud app access |
| Git verification fails | Run `git status` and resolve any changes |
| Files not syncing | Check logs: `cat dev_sync_logs/export_*.log` |
| Provider mirror contains generated files | Use `bash dev-sync-prune-excluded.sh --plan-out dev_sync_cleanup_plan.json` |
| rsync not found | Install: `brew install rsync` |
| rclone not found | Install: `brew install rclone` |

See [README.md](README.md#troubleshooting) for more details.

## Adding Custom Providers

See [README.md](README.md#development) — Development section for how to:
1. Subclass `CloudProvider`
2. Implement required methods
3. Register in factory function
4. Add to setup wizard

## Getting Help

1. **Quick start**: [QUICK_START.md](QUICK_START.md)
2. **Full guide**: [README.md](README.md)
3. **Operator guide**: [../DEV_SCRIPTS_README.md](../DEV_SCRIPTS_README.md)
4. **Command help**: `bash dev-sync-export.sh --help`

## File Statistics

- Total lines of code: ~1,500
- Python files: 5 (680 lines core logic)
- Bash scripts: 1 (420 lines, bash 3.2+ compatible)
- Documentation: 3 files (~25 KB)
- No external dependencies (uses standard Python library + rsync/rclone)

## Release Notes

### v2.0 (Multi-Provider)
- Support for 7 cloud providers
- Plugin architecture with CloudProvider classes
- Interactive setup wizard with auto-detection
- Backward compatible with v1 configurations
- Enhanced error handling and logging
- Comprehensive documentation
- Tested and validated
