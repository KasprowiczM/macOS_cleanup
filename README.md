[EN](README.md) | [PL](README.pl.md) | [ES](README.es.md) | [FR](README.fr.md) | [DE](README.de.md) | [IT](README.it.md) | [PT](README.pt.md)

<p align="center">
  <a href="https://macos-cleanup.64bit.site/"><img src="assets/brand-banner.svg" alt="macOS Cleanup" width="640" /></a>
</p>

# macOS Cleanup

**Version 4.0.2** · Apple Silicon Mac · macOS 11 or later · [Website](https://macos-cleanup.64bit.site/) · [Support](https://macos-cleanup.64bit.site/support) · [MIT license](LICENSE) · [Changes](CHANGELOG.md)

A local tool for careful disk cleanup on macOS. It measures first, shows you a plan, and acts only on what you approve. Most removals go to a quarantine folder from which you can restore them. It has a terminal interface and a plain command-line mode, and it never uses `sudo`.

## What it cleans

Every category has a tier. The tier decides how the tool treats it.

**Regenerable.** The owner of the data rebuilds it. "Clean safe" and an automatic run touch only the categories whose mode is `auto`. Out of the box that is only `app-caches`; every other regenerable category starts in `review`. In the Categories tab (`m`) you can switch a regenerable category that goes to quarantine to `auto`. `npm`, `yarn`, `pnpm` and `pip` run a native tool and can never be `auto`.

| Category | What it is | Undo |
|----------|-----------|------|
| `app-caches` | Caches of apps on a built-in allowlist | restorable |
| `xcode-derived` | Xcode DerivedData | restorable |
| `npx`, `gradle`, `cocoapods`, `cargo`, `swift-pm`, `bundler`, `composer` | Build and package caches, removed by moving them to quarantine | restorable |
| `npm`, `yarn`, `pnpm`, `pip` | Package-manager caches, pruned by the tool itself (`npm cache clean --force`, `yarn cache clean`, `pnpm store prune`, `pip cache purge`) | permanent |

**Review.** Costly to rebuild or visible to you. Each one needs your consent in the session. They are never part of an automatic run.

| Category | What it is | Undo |
|----------|-----------|------|
| `trash` | The contents of the Trash | restorable |
| `user-caches` | Other children of `~/Library/Caches` | restorable |
| `app-caches-review` | Caches of known apps that may hold offline data or be slow to rebuild | restorable |
| `user-logs`, `diagnostic-reports` | Old logs and crash reports in your home folder | restorable |
| `device-support` | Old iOS Device Support folders (the newest per platform is kept) | restorable |
| `pnpm-stale` | Stale pnpm store data | restorable |
| `ios-backups` | iOS device backups, confirmed one by one | restorable |
| `installers` | Old DMG, PKG and ISO files in Downloads | restorable |
| `system-logs`, `tmp` | System logs and temporary files outside your home folder | permanent, and only in permanent mode |
| `simulators`, `sim-runtimes` | Unavailable simulators and unusable simulator runtimes (`xcrun simctl`) | permanent |
| `brew`, `gem` | `brew cleanup --prune=all` and `gem cleanup`, which remove old installed versions | permanent |
| `docker` | `docker system prune -f` | permanent |
| `tm-snapshots` | Local Time Machine snapshots (`tmutil`); the newest one is kept | permanent |

`sim-runtimes`, `docker` and `tm-snapshots` run only when you pick them in an interactive run, never from "Clean safe" or an automatic run.

**Report only.** Measured and explained, never removed by this tool: `system-caches`, `xcode-archives`, `maven`, `android-avd`, `app-leftovers`, `browser-caches`, `browser-data`, `mail-data` and `mail-downloads`.

## How it keeps you safe

- **Nothing changes until you agree.** A scan or preview never touches your files. The default answer to every question is no.
- **Quarantine, not deletion.** Where the tool moves files itself, it moves them into a quarantine folder on the same disk and records what it moved, so `restore` can put them back. Quarantine frees no space until you purge it.
- **Permanent steps are labelled.** Native tool cleanups (`npm`, `yarn`, `pnpm`, `pip`, `brew`, `gem`, `docker`, `xcrun simctl`, `tmutil`) cannot be undone, and so cannot be restored. Permanent mode also deletes for good. The interface and the prompts say so every time.
- **A protected list that stays protected.** Mail, Messages, Calendars, Contacts, Keychains, password managers, browser profiles, Documents, Desktop, Photos, Music and Movies libraries, iCloud and other cloud folders, SSH and GPG keys, credential files, `~/.config`, source folders and Git working trees are never touched. So are this tool's own program, settings, state and quarantine folders.
- **Checked again just before acting.** Right before it removes an item, the tool checks that it still exists, is the same item that was planned, lies inside its category's allowed folders, is not in use, and is not too recent if you set a minimum age.
- **Automatic runs are narrow.** They are off by default. When you turn them on, they touch only the categories whose mode is `auto` (out of the box only `app-caches`), only through quarantine, and then purge quarantine runs past their retention period. They run no native tool and never use permanent mode.
- **Honest numbers.** Results show an estimate (the sum of the sizes of what the run acted on) and, when it can be measured, the actual change in free space. They often differ, and the interface says why. Sizes are shown in binary units: KiB, MiB, GiB.

Quarantine is an undo, not a backup. Keep a current backup before your first real cleanup.

## Requirements

- Apple Silicon Mac running macOS 11 Big Sur or later. Intel Macs are not blocked by the code but are outside official support.
- `bash` 3.2 or later, which macOS includes.
- Python 3.9 or later for the terminal interface, for plans (`plan` and `apply`) and for `migrate`. If it is missing, run `xcode-select --install`. Without Python the plain command-line mode still works for the other commands.
- A terminal at least 40 columns by 12 rows for the interface.
- Network access only to install and for an update you start yourself with `macos-cleanup update-self`. Cleaning, scanning and restoring never touch the network.

## Install

```bash
/bin/bash -c "$(curl -fsSL https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/install.sh)"
```

The installer downloads the release package and its `SHA256SUMS` file, checks the checksum, puts the program in `~/.local/share/macos-cleanup` and links `~/.local/bin/macos-cleanup`. It needs no `git`, never uses `sudo`, never changes your settings, state or quarantine, never installs the automatic run, and never starts a cleanup. To install a specific release: `install.sh --version 4.0.2`.

To check the download yourself first:

```bash
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.2/macos-cleanup-4.0.2.tar.gz
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.2/SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Only unpack the package if the check prints `OK`. Checksums protect against a damaged or partial download. The releases are not cryptographically signed, so a checksum fetched from the same place as the package does not prove who published it. More options and manual steps: [INSTALL.md](docs/user/INSTALL.md).

If `macos-cleanup` is not found afterwards, open a new terminal window and check that `~/.local/bin` is on your `PATH`.

## First run

```bash
macos-cleanup
```

In a terminal this opens the interface on the Dashboard. Without a terminal a plain `macos-cleanup` is a read-only scan. Press `S` to scan. A scan changes nothing. Press `P` for a preview of what a cleanup would do, then `C` to clean the safe categories, or choose categories in the Categories tab and press `X`.

`mac-cleanup` is the same command as `macos-cleanup`, and both work from any folder. Without arguments each opens the interface; `--cli` runs in plain terminal mode. The installer tells you when another program on your `PATH` answers to either name: typing that name would then run that program, not macOS Cleanup.

Plain text instead:

```bash
macos-cleanup scan
```

Before anything real, run `macos-cleanup doctor` to see your paths, free space, Full Disk Access status and local snapshots.

## The terminal interface

Seven tabs, reached with `1` to `7`:

| # | Tab | What it is for |
|---|-----|----------------|
| 1 | Dashboard | Scan, preview, clean. Live progress per category and the result of the last run |
| 2 | Categories | Every category with its tier, mode and size. Select what to clean |
| 3 | Quarantine | Restore a run, purge a run (you type the last part of its id), purge expired runs |
| 4 | History | Past runs and their reports. Apply a recent plan |
| 5 | Settings | Language and look, safety limits, rules, retention, schedule, paths, export and import |
| 6 | Diagnostics | Health checks, Full Disk Access, layout migration preview |
| 7 | Help | Keys, tiers, paths, version |

Main keys: arrows move, `Enter` opens or confirms, `Tab` switches pane, `Esc` goes back (or asks to stop a running job), `1` to `7` jump to a tab, `?` opens help, `L` shows the log, `q` quits. `/` searches and `s` sorts in the lists that offer them. The bottom line always shows the keys that work right now. Full details: [USER_GUIDE.md](docs/user/USER_GUIDE.md).

## Plain command-line use

`macos-cleanup` with a subcommand never opens the interface. So does `--cli`, and so does any run without a terminal. A plain `macos-cleanup` without a terminal is a read-only scan.

```bash
macos-cleanup scan                        # measure, change nothing
macos-cleanup plan                        # measure and write a plan file
macos-cleanup clean --safe                # categories in mode auto, after one question
macos-cleanup clean --only trash,npm      # exactly these categories, with a question per section
macos-cleanup quarantine list             # list restore points
macos-cleanup restore latest              # put the latest run back
macos-cleanup quarantine purge expired --apply   # permanently remove expired restore points
macos-cleanup doctor                      # check this Mac
macos-cleanup history                     # list past runs
```

`scan`, `plan`, `quarantine list`, `history` and `doctor` are read-only. `clean`, `apply`, `restore`, and `quarantine purge ... --apply` change things. `quarantine purge` without `--apply` only previews. A restore never overwrites: an item whose original place is taken is skipped and stays in quarantine, and the restore then ends with a warning (exit status 1), not a failure. See the table of every command and flag in the [user guide](docs/user/USER_GUIDE.md).

## Where files live

| What | Where | Override |
|------|-------|----------|
| Program | `~/.local/share/macos-cleanup` | `MACOS_CLEANUP_HOME` |
| Settings and rules | `~/.config/macos-cleanup` | `MACOS_CLEANUP_CONFIG_DIR` |
| Logs, reports, plans, history | `~/.local/state/macos-cleanup` | `MACOS_CLEANUP_STATE_DIR` |
| Quarantine (restore points) | `~/Library/Application Support/macOS_cleanup/quarantine` | `MACOS_CLEANUP_QUARANTINE_DIR` |

Overrides must be absolute paths. Quarantine must be on the same disk as your home folder. Upgrading replaces only the program. Settings, state and quarantine stay.

## Automatic runs

Off by default, and the installer never turns them on. You enable them in **Settings**, or with:

```bash
macos-cleanup schedule install --time 10:30
macos-cleanup schedule status
macos-cleanup schedule remove
```

This installs one macOS LaunchAgent (`com.github.kasprowiczm.macos-cleanup`). A scheduled run does only two things: it moves items of categories whose mode is `auto` (out of the box only `app-caches`) into quarantine, and it purges quarantine runs past their retention period. It runs no native tool, nothing from the review tier, and never permanent mode. It writes a normal entry to History.

## Update and uninstall

Run the installer again, or `macos-cleanup update-self`, to upgrade. The previous version is kept next to the program as `.previous`. To remove the tool:

```bash
macos-cleanup uninstall --dry-run
macos-cleanup uninstall
```

It asks whether to keep your settings and your run history, and it never deletes the quarantine unless you pass `--purge-quarantine --yes`. See [UNINSTALL.md](docs/user/UNINSTALL.md). Coming from 3.x? Read [MIGRATING_FROM_V3.md](docs/user/MIGRATING_FROM_V3.md).

## Privacy

Scanning, cleaning and restoring work offline; the network is used only to install and for `update-self`. The tool sends no paths, results or usage data anywhere, and has no telemetry. Logs, reports and plans stay in the state folder on your Mac. Use `--redact` to replace your home folder with `~` and leave out your user and host name before you share a report.

## Limits and known gaps

- Quarantine frees no space until you purge it, and local snapshots can hold on to deleted blocks after that. Space returns when macOS reclaims it.
- Sizes are upper-bound estimates. APFS clones and shared blocks are not detected.
- Without Full Disk Access some folders cannot be read. The scan is then marked partial and those sizes are lower bounds.
- Native tool cleanups and permanent mode cannot be undone.
- Report-only categories are never removed. Clean them with their own tools.
- Releases are verified by checksum, not by a cryptographic signature.
- Apple Silicon with macOS 11 or later is the supported setup. Other setups are untested.

## Documentation

[User guide](docs/user/USER_GUIDE.md) · [Install](docs/user/INSTALL.md) · [Uninstall](docs/user/UNINSTALL.md) · [Migrating from 3.x](docs/user/MIGRATING_FROM_V3.md) · [Changes](CHANGELOG.md)

## Support

[macos-cleanup.64bit.site/support](https://macos-cleanup.64bit.site/support)

## License

[MIT](LICENSE)

> **Use at your own risk.** The tool is built to ask before it acts and to keep the way back open, but no software is free of bugs. Back up first.
