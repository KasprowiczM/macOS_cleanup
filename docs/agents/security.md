# Security Rules — macOS_cleanup

## Absolute Rules (NEVER violate)

1. **Mail** — do not touch `~/Library/Mail` (email data).
2. **Keychain** — do not touch `~/Library/Keychains` (system passwords).
3. **Browsers** — do not modify profiles containing passwords/cookies.
4. **Consent** — every operation requires conscious user consent.
5. **Default NO** — no response = no consent = no action.

## UX/DX Model

The target communication model is `SAFE` / `REVIEW` / `DANGEROUS` and phases `analyze` / `plan` / `apply`.

- `analyze`: scan and report only; equivalent to `--dry-run`.
- `plan`: explicit candidates, sizes, impacts, rollback info, and items requiring a decision.
- `apply`: real action after consent; equivalent to `--interactive`, limited `--auto-safe`, or `--purge-quarantine ... --apply`.

Mapping to the current YAML: `safe` = `SAFE`, `ask` = `REVIEW`, `never` = `DANGEROUS` / `NEVER_TOUCH`.

Rules:
- `SAFE` does not mean bypassing guardrails. Still use `safe_remove()`, dry-run, and quarantine where applicable.
- `REVIEW` requires explaining the impact and a human decision.
- `DANGEROUS` is not a category for automatic cleaning. It's a block or a hint for manual handling outside the script.

## Removal Function Hierarchy

```
safe_remove()          ← The ONLY permitted removal function
  └─ is_protected_path()  ← checks before every operation
  └─ $DRY_RUN check       ← checks before every operation
  └─ REMOVE_MODE          ← quarantine (default) or permanent
  └─ journal JSONL        ← records operation audit
  └─ confirm_category()   ← in interactive mode
```

> [!CAUTION]
> Using `rm` directly (outside of `safe_remove`) is a hard violation of the project policy.
> Controlled exception: quarantine purge removes only direct runs under `QUARANTINE_ROOT` and requires `--purge-quarantine ... --apply`.
> Controlled exception: native tools like `brew cleanup`, `docker system prune`, `xcrun simctl delete unavailable`, and `tmutil deletelocalsnapshots` can do their own cleanup after confirmation; they must record `native_command` to the journal and clearly communicate the lack of a quarantine rollback. Native package-manager commands are irreversible and are not quarantined (`rollback:false`).

## Path Protection

The `is_protected_path()` function automatically blocks:
- `~/Library/Mail`, `~/Library/Keychains`, `~/Library/Safari/Bookmarks*`
- `/System/`, `/Library/` (system-wide)
- `/Users/` (other users)
- broad roots: `/`, `$HOME`, `~/Library`, `~/Library/Application Support`, `~/Library/Preferences`, `~/Library/Containers`, `~/Library/Group Containers`, `/private`, `/var`, `/tmp`, `/private/tmp`

`app-leftovers` is a report-only category: heuristics might point to data of an active app, so the script does not delete these paths automatically.
`--yes` in non-interactive mode does not approve `MEDIUM`/`HIGH` categories, Time Machine, or iOS backups.

Apply re-checks `is_protected_path` and the current policy for every target, including native commands. Malformed plans fail before the first mutation.

## Artifact retention

Artifact retention is explicit `--prune-artifacts` only. Read-only modes (`analyze`, `list`, `plan`, `--dry-run`) must not delete logs or journals.

## What is NEVER removed

- Mail: `~/Library/Mail`, Apple Mail sandbox, Thunderbird, Outlook, Spark, and other local message stores.
- Identity and secrets: Keychain, password managers, SSH/GPG keys, credential stores.
- Browser profiles: cookies, passwords, sessions, history, bookmarks, extensions, and entire profiles in `Application Support`.
- User data: `~/Documents`, `~/Desktop`, Photos, Music, Movies.
- Developer signing: provisioning profiles, certificates, and keychains.
- The quarantine directory `~/Library/Application Support/macOS_cleanup`.

Do not bypass this list by deleting the parent directory.

## Quarantine and Restore

- The default real removal mode is `REMOVE_MODE=quarantine`.
- User paths handled by `safe_remove()` are moved to `~/Library/Application Support/macOS_cleanup/quarantine/<run_id>/items/...`.
- The report creates machine-readable plan entries in `reports/journal_<run_id>.jsonl`; real `safe_remove()` operations append execution events.
- Quarantine additionally creates `reports/restore_<run_id>.tsv`.
- `--restore latest|<manifest>` restores only from the quarantine directory, only to the user space, and never to protected paths.
- Restore blocks target paths with symlinked parent directories so the manifest cannot write through a link outside the verified scope.
- `--purge-quarantine latest|<run_id>|all` is a preview; permanent deletion requires `--apply`.
- Quarantine does not immediately reclaim space. Space is reclaimed by `--permanent` or a later quarantine purge.
- Paths outside `$HOME` are not quarantined in default mode; they require `--permanent` after analysis.
- Quarantine metadata is fail-closed: if the journal or restore TSV cannot be written, roll back the move and do not count success. Counters increment only after durable metadata.

Quarantine is not a backup. Before a real apply, the user should have a current system backup. Treat iOS backups, Time Machine, local mail archives, and distribution archives as at least `REVIEW`, and if unsure, as `DANGEROUS`.

## Mail and Browsers

Mail guidelines:
- Do not delete local mail stores or client sandboxes.
- In documentation, direct the user to the mail client's UI, archiving, or export.
- Treat POP accounts and local archives as potentially the only copy of the data.

Browser guidelines:
- Browser cache might be a `REVIEW` candidate; precise leaf cache might be `SAFE`.
- Browser profiles are `DANGEROUS` because they contain sessions, cookies, passwords, history, bookmarks, and extensions.
- Browser sync is not a sufficient assumption to automatically delete a profile.

## Installer

- Refuse a dirty checkout (exit 1); do not overwrite local edits.
- Abort on SHA256 mismatch (exit 1); do not treat it as a warning.
- Never run `git reset --hard`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Bad CLI argument |
| 99 | Security violation |

## Secrets and .env

- The `.claudeignore` file excludes `.env*`, `secrets/` from the Claude context.
- Permissions in `.claude/settings.json` block reading `.env`, `*.pem`, `*.key` files.
- Secrets should not be in the repo at all.

## Dev-sync overlay

- `dev-sync/` is used only for the private restoration overlay: ignored local files, `.dev_sync_config.json` configuration, and optional local `.env` / `.dev.vars`.
- The overlay is not GitHub. Tracked source must still be committed and pushed via Git.
- Default dev-sync exclusions block `logs/`, `reports/`, `graphify-out/`, caches, dependency folders, `secrets/`, `.ssh/`, keys/certificates, and machine-local agent settings.
- Hard excludes (`.git/`, `.ssh/`, `secrets/`, key material) ignore case and apply to every import source, including an rclone remote listing. Overlay files whose case-folded path matches a tracked file are never imported.
- `dev-sync-prune-excluded.sh` and `dev-sync-purge-quarantine.sh` operate strictly inside the configured provider mirror. This is a controlled exception to `safe_remove()`: it uses `safe_relpath()` / `resolve_under()` and the plan -> quarantine -> verify -> purge workflow, not broad deletion in the repo.
- Do not use `rm`, `truncate`, `xattr`, `chflags`, or placeholder edits in `~/Library/CloudStorage`; for Proton offload use `dev-sync-proton-status.sh --full`, and then Finder/Proton Drive "Remove Download".
- Never delete the destination before a verified copy.
- On prune, move the symlink leaf; do not follow it to the target.
