# Installation

**macOS Cleanup 4.0.2** · Apple Silicon Mac · macOS 11 or later · Website: <https://macos-cleanup.64bit.site/>

Installing puts the program on your Mac and adds the `macos-cleanup` command. It cleans nothing and starts no scan.

## Requirements

| Need | Notes |
|------|-------|
| Apple Silicon Mac, macOS 11 Big Sur or later | Intel Macs are not blocked by the code but are outside official support. |
| `bash` 3.2 or later | Included with macOS. |
| Python 3.9 or later | Needed for the terminal interface, for `plan` and `apply`, and for `migrate`. If it is missing, run `xcode-select --install`, then the installer again. The installer never starts that for you. |
| Internet access | Only to download the release package from GitHub, at install time and when you start an update with `macos-cleanup update-self`. Cleaning, scanning and restoring never touch the network. |

You do not need `git` and you do not need `sudo`.

## Install

```bash
/bin/bash -c "$(curl -fsSL https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/install.sh)"
```

The installer:

1. Finds the latest release (or the one you ask for) and downloads the package and its `SHA256SUMS` file.
2. Checks the package against its SHA-256 checksum. If it does not match, nothing is installed.
3. Unpacks the package next to the target folder and swaps it in. The previous version is kept as `.previous`.
4. Writes `.install-info` in the program folder (version, install time, source, checksum).
5. Links `~/.local/bin/macos-cleanup` to the program.

It never touches your settings, state or quarantine, never uses `sudo`, never installs the automatic run, and never starts a cleanup.

To install a specific release, download `install.sh` and pass the version:

```bash
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/install.sh
/bin/bash install.sh --version 4.0.2
```

Installer options:

| Option | Meaning |
|--------|---------|
| `--version X.Y.Z` | Install that release instead of the latest |
| `--dir DIR` | Program folder (default `~/.local/share/macos-cleanup`) |
| `--dry-run` | Print what would happen. Writes nothing and uses no network |
| `--configure-shell` | Add `~/.local/bin` to `PATH` in your zsh or bash profile (the installer never edits a profile otherwise) |
| `--quiet` | Print only warnings and errors |

Prefer to read the installer first? Open `install.sh` from the release page before you run it.

If `macos-cleanup` is not found afterwards, open a new terminal window and check that `~/.local/bin` is on your `PATH`.

`mac-cleanup` is the same command as `macos-cleanup`, and both work from any folder. Without arguments each opens the interface; `--cli` runs in plain terminal mode. The installer tells you when another program on your `PATH` answers to either name: typing that name would then run that program, not macOS Cleanup.

## Where things go

| What | Where |
|------|-------|
| The program | `~/.local/share/macos-cleanup` (the previous version is kept as `.previous`) |
| The command | `~/.local/bin/macos-cleanup` |
| Settings and rules | `~/.config/macos-cleanup` |
| Logs, reports, plans, history | `~/.local/state/macos-cleanup` |
| Quarantine (restore points) | `~/Library/Application Support/macOS_cleanup/quarantine` |

Overrides are `MACOS_CLEANUP_HOME`, `MACOS_CLEANUP_CONFIG_DIR`, `MACOS_CLEANUP_STATE_DIR` and `MACOS_CLEANUP_QUARANTINE_DIR`. They must be absolute paths.

## Check the download yourself

The installer checks the checksum for you. To do it by hand:

```bash
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.2/macos-cleanup-4.0.2.tar.gz
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.2/SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```

The check must print `macos-cleanup-4.0.2.tar.gz: OK`. If it prints `FAILED`, delete the files and download again.

A checksum protects against a damaged or partial download. The releases are not cryptographically signed, so a checksum fetched from the same place as the package does not prove who published it.

## Manual install

After a successful check:

```bash
mkdir -p ~/.local/share/macos-cleanup ~/.local/bin
tar -xzf macos-cleanup-4.0.2.tar.gz --strip-components=1 -C ~/.local/share/macos-cleanup
ln -sf ~/.local/share/macos-cleanup/bin/macos-cleanup ~/.local/bin/macos-cleanup
macos-cleanup version
```

The last command prints `macos-cleanup 4.0.2`. A manual install has no `.previous` copy to go back to.

## First run

```bash
macos-cleanup doctor
macos-cleanup
```

`doctor` shows your paths, free space, Full Disk Access status and local snapshots, and changes nothing. The second command opens the interface. Press `S` for a scan, which also changes nothing.

## Upgrade

Run the installer again, or run `macos-cleanup update-self`. `update-self --check` only compares versions; `update-self` downloads, verifies and installs the latest release, and `update-self --rollback` goes back to the `.previous` copy. Nothing checks for updates by itself. Only the program folder is replaced. Your settings, state and quarantine stay as they are. `update-self` works on a copy made by the installer; a copy unpacked by hand has no `.install-info` and is refused.

## Coming from 3.x

Version 3 ran from a git folder and wrote logs and reports inside it. See [MIGRATING_FROM_V3.md](MIGRATING_FROM_V3.md). If the installer finds an old checkout, it prints one line suggesting `macos-cleanup migrate --preview`. It does not touch the old folder.

## Troubleshooting

| Problem | What to do |
|---------|-----------|
| Checksum mismatch | Delete the download and try again. If it repeats, do not install; ask for help at <https://macos-cleanup.64bit.site/support> |
| `command not found` after install | Open a new terminal. Check `echo $PATH` for `~/.local/bin` |
| Typing `macos-cleanup` or `mac-cleanup` starts a different program | Another program earlier on your `PATH` has that name (the installer names the file). Remove or rename it, or run `~/.local/bin/macos-cleanup` by its full path |
| Python 3.9 not found | `xcode-select --install`, then run the installer again |
| An older file named `macos-cleanup` is in `~/.local/bin` | Move it away and run the installer again |
