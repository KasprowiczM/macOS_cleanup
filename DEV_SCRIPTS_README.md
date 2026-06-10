# Dev Sync Scripts README

Operator guide for the single-repo `dev-sync` scripts in `macOS_cleanup`.

For full command details, see:

- `dev-sync/README.md`
- `dev-sync/QUICK_START.md`

## What Git Stores

Git remains the source of truth for tracked project files:

- cleanup runtime scripts in `cleanup_all.sh`, `lib/`, and `config/`
- tests in `tests/`
- public docs and agent instructions
- graphify agent maps when intentionally committed
- the dev-sync implementation itself

Tracked files should be committed and pushed before you treat a machine as fully backed up.

## What The Provider Stores

The configured provider stores only a curated private recovery overlay:

- `.dev_sync_config.json`
- optional local env files such as `.env`, `.env.local`, `.env.*.local`, `.dev.vars`
- local editor/project state such as `.vscode/` or `.idea/`
- ignored or untracked local files that cannot be recreated from Git plus normal setup

The overlay is manifest-backed for local filesystem providers. Export writes `.dev_sync_manifest.json` into the provider mirror, and import prefers that manifest so old stale files are not restored accidentally.

## What Is Excluded

The overlay intentionally excludes files you can recreate or should not sync:

- cleanup outputs: `logs/`, `reports/`
- generated maps/caches: `graphify-out/`
- dependency folders and build outputs: `node_modules/`, `.venv/`, `dist*/`, `build*/`, `out/`, `output/`
- Python caches: `__pycache__/`, `.pytest_cache/`, `*.pyc`
- tool caches and test output: `.cache/`, `.turbo/`, `.vite/`, `coverage/`, `test-results/`
- secrets and key material: `secrets/`, `.ssh/`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.crt`, `*.cer`
- logs, temp files, backups, rejects, `.DS_Store`, `.fuse_hidden*`
- external skill repos/caches such as `.agent/skills/`, `.agent/superpowers/`, `.claude/skills/`, `.gemini/skills/`
- machine-local agent settings such as `.claude/settings.local.json`

Recreate excluded dependencies and generated outputs from their source instead of syncing them through the provider.

## Daily Export

Run this after private local files change:

```sh
bash dev-sync/dev-sync-export.sh
bash dev-sync/dev-sync-verify-full.sh
bash dev-sync/dev-sync-prune-excluded.sh
```

Expected result:

- `verify-full` prints `PASS`
- `prune-excluded` reports `0` cleanup candidates

Use `--dry-run --verbose` first when you want to inspect the selected paths without copying.

## Clean Bad Provider Sync

If generated files or stale files are already present in the provider mirror, use a saved cleanup plan.

```sh
bash dev-sync/dev-sync-prune-excluded.sh --plan-out dev_sync_cleanup_plan.json
```

Inspect the printed summary and the JSON plan. Then quarantine exactly the reviewed plan:

```sh
bash dev-sync/dev-sync-prune-excluded.sh --apply-plan dev_sync_cleanup_plan.json
bash dev-sync/dev-sync-verify-full.sh
bash dev-sync/dev-sync-purge-quarantine.sh
```

If verification passes and the quarantine has been reviewed:

```sh
bash dev-sync/dev-sync-purge-quarantine.sh --apply
```

Do not directly delete broad directories in a cloud provider mirror. The prune command is plan-first by design.

## Check Proton Upload Before Freeing Disk

Before using Proton Drive or Finder to remove local downloads, run:

```sh
bash dev-sync/dev-sync-proton-status.sh --full
```

Only continue if it reports that the overlay is safe to offload.

Then use Finder or Proton Drive's own `Remove Download` action on the configured provider project folder. Do not use `rm`, `truncate`, `xattr`, `chflags`, or placeholder edits inside `CloudStorage`; those can delete cloud data or corrupt File Provider state.

## Restore On A New Mac

1. Clone this repo from Git.
2. Run provider setup if `.dev_sync_config.json` is missing:

```sh
bash dev-sync/provider_setup.sh
```

3. Confirm the provider destination points at the right project mirror.
4. Restore the private overlay:

```sh
bash dev-sync/dev-sync-import.sh
bash dev-sync/dev-sync-verify-full.sh
```

5. Reinstall or regenerate excluded dependencies, logs, reports, and graphify outputs only if needed.

## Git Verification

Use this before relying on Git as the tracked-file backup:

```sh
bash dev-sync/dev-sync-verify-git.sh
```

It checks that tracked files are clean, an upstream exists, and the local branch is not ahead of upstream.
