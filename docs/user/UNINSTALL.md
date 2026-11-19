# Uninstall

**macOS Cleanup 4.0.5.** Removing it never touches your apps or the files you keep.

## Steps

```bash
macos-cleanup uninstall --dry-run
macos-cleanup uninstall
```

The first command shows what would be removed and removes nothing. The second asks whether to keep your settings (default yes) and your run history in the state folder (default no, so it is removed), then asks once more before it removes the program. It never uses `sudo`.

| Option | Meaning |
|--------|---------|
| `--dry-run` | Show what would be removed. Removes nothing |
| `--yes` | Do not ask. Keeps your settings, removes the state folder |
| `--keep-state` | Keep the run history, caches and migration backups in the state folder |
| `--purge-data` (or `--purge`) | Also remove your settings |
| `--keep-config` | Keep your settings (the default) |
| `--delete-quarantine` (or `--purge-quarantine`) | Also delete the quarantine. It needs `--yes` as well, and without it the quarantine is always kept |

## What is removed

- The automatic run, if you turned it on: the LaunchAgent is stopped first, then its file is removed.
- The command `~/.local/bin/macos-cleanup`.
- The program folder `~/.local/share/macos-cleanup` and its `.previous` copy.
- Your run history, logs, reports and plans in `~/.local/state/macos-cleanup`, unless you keep them (see below).

## What is kept

The uninstaller keeps:

- your settings and rules in `~/.config/macos-cleanup`, unless you pass `--purge-data` or answer no to the question;
- your logs, reports, plans and history in `~/.local/state/macos-cleanup`, only if you pass `--keep-state` or answer yes to the question (otherwise this folder is removed);
- your quarantine in `~/Library/Application Support/macOS_cleanup/quarantine`, always, unless you pass `--delete-quarantine` together with `--yes`. It is the only copy of your restore points. Before you uninstall, restore anything you want back, or purge what you no longer need:

```bash
macos-cleanup quarantine list
macos-cleanup restore latest
```

## What is not removed

- Your apps, Homebrew, Python or any other tool.
- Files that earlier cleanups already removed permanently.
- Anything left from 3.x in your old git folder. Delete that folder yourself when you no longer need it.
- Your shell profile. The tool does not edit it.

## If `macos-cleanup` does not run

If typing `macos-cleanup` or `mac-cleanup` starts a different program, another program earlier on your `PATH` has that name: remove or rename it, or call `~/.local/bin/macos-cleanup` by its full path.

Use the uninstaller from the release page:

```bash
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/uninstall.sh
/bin/bash uninstall.sh --dry-run
/bin/bash uninstall.sh
```

Or remove the pieces by hand, in this order:

```bash
launchctl bootout "gui/$(id -u)/com.github.kasprowiczm.macos-cleanup" 2>/dev/null
rm -f ~/Library/LaunchAgents/com.github.kasprowiczm.macos-cleanup.plist
rm -f ~/.local/bin/macos-cleanup
rm -rf ~/.local/share/macos-cleanup ~/.local/share/macos-cleanup.previous
```

The `launchctl` line stops the automatic run if it was installed. It is safe to run when it was not. This does not touch your settings, state or quarantine.
