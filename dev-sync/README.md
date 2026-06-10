# Dev Sync System

Single-repo recovery sync for private/local `macOS_cleanup` files.

The recovery model is:

- GitHub stores tracked source files.
- Proton Drive or another configured provider stores a private overlay for ignored, untracked, and local-only files.
- Rebuildable outputs, dependency folders, cleanup reports/logs, graphify outputs, key material, and external skill repos are excluded from the provider overlay.

## Commands

```bash
bash dev-sync/provider_setup.sh
bash dev-sync/dev-sync-export.sh [--dry-run] [--verbose]
bash dev-sync/dev-sync-import.sh [--dry-run] [--verbose]
bash dev-sync/dev-sync-verify-git.sh
bash dev-sync/dev-sync-verify-full.sh [--verbose]
bash dev-sync/dev-sync-prune-excluded.sh [--plan-out FILE] [--apply-plan FILE] [--verbose]
bash dev-sync/dev-sync-purge-quarantine.sh [--apply] [--verbose]
bash dev-sync/dev-sync-proton-status.sh [--full] [--sample N] [--limit N] [--verbose]
```

Root compatibility wrappers also exist, for example `bash dev-sync-export.sh`.

## Standard Workflow

1. Commit and push tracked source changes.
2. Export private overlay files:

```bash
bash dev-sync/dev-sync-export.sh
```

3. Verify reconstructability:

```bash
bash dev-sync/dev-sync-verify-full.sh
```

4. Check for stale or generated files in the provider mirror:

```bash
bash dev-sync/dev-sync-prune-excluded.sh
```

Expected state: `verify-full` passes and `prune-excluded` reports zero cleanup candidates.

## Configuration

The local config is `.dev_sync_config.json` in the repo root. It is intentionally ignored by Git.

Important fields:

- `project_name`
- `provider`
- `provider_path`
- `proton_project_root`
- `rclone_remote`
- `rclone_remote_path`
- `exclude_patterns`
- `include_always`

Run the wizard to create or replace it:

```bash
bash dev-sync/provider_setup.sh
```

For Proton, old configs that use `proton_project_root` still work. If `provider_path` points at a Proton mount and `project_name` is `macOS_cleanup`, the provider mirror is `<provider_path>/macOS_cleanup`.

## What Gets Synced

The export candidate set is Git-based:

1. untracked files
2. ignored files
3. minus excluded/generated patterns
4. plus always-include private/local patterns

Common private overlay files:

- `.env`, `.env.local`, `.env.*.local`
- `.dev_sync_config.json`
- `.dev.vars`, `.dev.vars.*`
- `.vscode/`, `.idea/`

Common exclusions:

- `node_modules/`, `.node_modules*/`
- `.agent/skills/`, `.agent/superpowers/`, `.claude/skills/`, `.gemini/skills/`
- `.claude/settings.local.json`, `.gemini/settings.local.json`
- `dist*/`, `build*/`, `out/`, `output/`, `.next/`, `.open-next/`
- `.cache/`, `.turbo/`, `.vite/`, `.wrangler/`, `.npm-cache/`, `.bun-cache/`
- `coverage/`, `playwright-report/`, `test-results/`
- `logs/`, `reports/`, `graphify-out/`
- `secrets/`, `.ssh/`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.crt`, `*.cer`
- logs, temp files, backup files, `.DS_Store`, `.fuse_hidden*`

## Manifest Behavior

Local filesystem providers write `.dev_sync_manifest.json` into the provider mirror on export.

Import prefers the manifest when present. This prevents old provider files from being restored just because they still physically exist from an older append-only export.

Import also skips provider files that are tracked by Git, so GitHub remains authoritative for source files.

## Cleanup And Quarantine

Plan cleanup:

```bash
bash dev-sync/dev-sync-prune-excluded.sh --plan-out dev_sync_cleanup_plan.json
```

Apply the reviewed plan:

```bash
bash dev-sync/dev-sync-prune-excluded.sh --apply-plan dev_sync_cleanup_plan.json
```

This moves exact planned candidates into `<provider-project-root>/dev_sync_quarantine/<timestamp>/`.

After `verify-full` passes and the quarantine has been reviewed:

```bash
bash dev-sync/dev-sync-purge-quarantine.sh --apply
```

Without `--apply`, purge is a dry run.

## Proton Offload Check

Before freeing local Proton Drive cache:

```bash
bash dev-sync/dev-sync-proton-status.sh --full
```

Only use Finder or Proton Drive's own `Remove Download` action after the command reports safe. Do not remove files inside `~/Library/CloudStorage` with shell commands.

## New Mac Restore

```bash
git clone <repo-url>
cd macOS_cleanup
bash dev-sync/provider_setup.sh
bash dev-sync/dev-sync-import.sh
bash dev-sync/dev-sync-verify-full.sh
```

Then recreate excluded dependencies and external skill repos from their original sources only if needed.

## Logs

Logs are written to `dev_sync_logs/` and are ignored by Git:

- `*-export.log`
- `*-import.log`
- `*-verify-full.log`
- `*-prune-excluded.log`
- `*-purge-quarantine.log`
- `*-proton-status.log`
