# User guide (English)

**macOS Cleanup 4.0.2** · Apple Silicon Mac · macOS 11 or later

## What it does

macOS Cleanup measures what can be cleaned on your Mac, shows you a plan, and acts only on what you approve. It has two faces: a terminal interface (`macos-cleanup`) and a plain command-line mode (`macos-cleanup scan`, `macos-cleanup clean`, and so on). Both run the same engine and show the same facts.

A cleanup follows one path:

```
measure  ->  plan  ->  you consent  ->  act  ->  report
```

Measuring never changes anything. Acting happens only for items you approved, and each one is checked again right before it is touched.

## What it never does

- It never uses `sudo` and never asks for your password.
- It never touches the protected list: Mail, Messages, Calendars, Contacts, Keychains, password managers, browser profiles, Documents, Desktop, Photos, Music and Movies libraries, iCloud and other cloud-synced folders, SSH and GPG keys, credential files, `~/.config`, developer source folders, Git working trees (outside the Trash), and this tool's own program, settings, state and quarantine folders.
- It never removes report-only categories (see [Tiers](#tiers)).
- Scanning, cleaning and restoring never use the network. The network is used only to install and for an update you start yourself with `macos-cleanup update-self` (or Check for updates in the Help tab).
- It never runs a native cleanup tool or a review-tier category in an automatic run.

## Tiers

| Tier | Meaning | Default mode | In "Clean safe" | In an automatic run |
|------|---------|--------------|-----------------|---------------------|
| Regenerable | The owner of the data rebuilds it | `review`; `app-caches` is `auto` | only categories in mode `auto` | only categories in mode `auto`, through quarantine only |
| Review | Costly to rebuild or visible to you | `review` | no, asks per category | never |
| Report only | Measured and explained, never removed | `skip` | no | no |

Every category also has an undo state:

| Mark | Meaning |
|------|---------|
| `restorable` | Moved into quarantine. `restore` puts it back. |
| `permanent` | Removed by a native tool, or in permanent mode. It cannot be restored. |
| `not removed` | Report only. |

Out of the box only `app-caches` is in mode `auto`. In the Categories tab (`m`) you can switch any other regenerable category that goes to quarantine to `auto`. `npm`, `yarn`, `pnpm` and `pip` run a native tool and can never be `auto`.

Native tool cleanups are permanent: `npm`, `yarn`, `pnpm`, `pip`, `brew`, `gem`, `docker`, `xcrun simctl`, `tmutil`. `system-logs` and `tmp` live outside your home folder and can only be removed in permanent mode, so in the default quarantine mode they are skipped with the reason "needs permanent". `sim-runtimes`, `docker` and `tm-snapshots` run only from an interactive run you start yourself.

The full category list, by tier, is in the [README](../../README.md#what-it-cleans). `macos-cleanup` can also print it with each category's tier and current mode: `bash cleanup_all.sh --cli --list-categories`. Add `--json` to get the last scan sizes as well.

## Opening the interface

```bash
macos-cleanup
```

`mac-cleanup` is the same command as `macos-cleanup`, and both work from any folder. Without arguments each opens the interface; `--cli` runs in plain terminal mode. The installer tells you when another program on your `PATH` answers to either name: typing that name would then run that program, not macOS Cleanup.

In a terminal this opens the interface on the Dashboard. In a script, over SSH without a terminal, or when output is piped, you get plain text instead. Other ways in:

```bash
macos-cleanup ui categories      # open on a specific tab
macos-cleanup --tui              # require the interface; exits with 2 if there is no terminal
```

`ui` accepts `dashboard`, `categories`, `quarantine`, `history`, `settings`, `diagnostics` or `help`. The window needs at least 40 columns by 12 rows. If Python 3.9 or later is missing, or `TERM` is `dumb`, a plain run falls back to text with one line of explanation, while `--tui` stops with exit code 2.

Keys that work everywhere:

| Key | Action |
|-----|--------|
| Arrow keys | Move |
| `Enter` | Open or confirm |
| `Tab` | Next pane |
| `Esc` | Go back, close a dialog, or stop a running job (it asks first) |
| `1` to `7` | Jump to a tab |
| `L` | Show the full log |
| `?` | Help for the current tab |
| `q` | Quit |

`/` searches and `s` sorts in the lists that offer them (Categories, Settings and the contents of a quarantine run). The mouse works too. The bottom line always lists the keys that work right now.

## The tabs

### 1. Dashboard

**Zones.** A summary card for the last run (estimated, measured, quarantined), a run panel with one row per category (status symbol, name, progress, size), an item pane for the selected category, and a log.

| Key | Action | Changes files? |
|-----|--------|----------------|
| `S` | Scan | no |
| `P` | Preview: build the plan and show what a cleanup would do | no |
| `C` | Clean safe: the categories whose mode is `auto`. A dialog states the rules and asks first | yes |
| `X` | Clean selected: the categories you selected in the Categories tab. A dialog lists them and asks first | yes |
| `Esc` | Stop the running job (it asks first) | stops it |

The keys also work in lowercase. After a run the result page is shown; the action keys wait until you close it with `Esc` (or the Done button), and the key line says so. The result card shows "estimated X, measured Y" and why they can differ. See [Honest space accounting](#honest-space-accounting).

### 2. Categories

**Zones.** A list (category, tier badge, mode, size, undo mark) and a detail pane (what it is, the folders it covers, the native command if any, its largest items from the last plan).

| Key | Action |
|-----|--------|
| `Space` | Select or unselect |
| `a` | Select every regenerable category |
| `n` | Select none |
| `s` | Sort the list |
| `/` | Search |
| `m` | Cycle the mode: `auto`, `review`, `skip`. Saved to `category-modes.tsv` |
| `Enter` | Show details |
| `X` | Clean the selected categories |

Modes in short: `auto` means "Clean safe" may include it; `review` means it is always asked about; `skip` means it is never processed. Setting `auto` on a review-tier category is saved, but the interface then shows "consent still asked": review-tier categories never run without your confirmation.

### 3. Quarantine

**Zones.** A list of runs (run id, age, size, items, manifest state, expired) and a contents pane showing the first 200 rows of the selected run's manifest.

| Key | Action | Notes |
|-----|--------|-------|
| `r` | Restore the selected run, or the items you marked | A preview opens first (what goes back, what is skipped). Its Run button is the one confirmation; Cancel is selected first |
| `p` | Purge the selected run | Permanent. You type the last part of the run id (the digits after the last underscore) or the whole id |
| `E` | Purge every expired run | Permanent. A dialog asks first |
| `o` | Show the run folder in Finder | Read-only |

In the contents pane `Space` marks an item, `a` marks all visible, `n` clears the marks and `r` restores the marked items (the whole run when none is marked). A restore never overwrites: an item whose original place is taken is skipped and stays in quarantine. The manifest state is `ok`, `legacy` (a restore list carried over from 3.x) or `missing` (nothing to restore from).

### 4. History

**Zones.** A list of runs, a summary pane, and a report viewer.

| Key | Action | Notes |
|-----|--------|-------|
| `Enter` | Open the report | Read-only |
| `A` | Apply this plan | Only for a plan younger than 24 hours. You choose safe items only or safe plus review items; each review item is asked again |
| `f` | Filter by run type | |
| `y` | Copy the report path | |
| `o` | Show the run folder in Finder | Read-only |

### 5. Settings

Sections: look, safety, rules, performance, history, schedule, paths, system. `Enter` edits a row, `Space` switches an on/off row, left and right adjust a number or choice, `d` puts one setting back to its default, `/` searches. Export, import and reset are rows in the System section. Every row is explained in [Settings](#settings).

### 6. Diagnostics

**Zones.** A checks list and a facts pane, from `macos-cleanup doctor`.

| Key | Action |
|-----|--------|
| `F` | Open the Full Disk Access pane of System Settings |
| `M` | Show the output of `macos-cleanup migrate --preview` |
| `u` | Show the paths that could not be read |
| `P` | Show the protected paths |
| `r` | Refresh the checks |

### 7. Help

Keys, a short explanation of the tiers, your paths, the version and the license. `U` checks for a newer release when you ask (it is the only thing in the interface that uses the network) and offers to install it.

## Running a clean

**Clean safe** (`C`, or `macos-cleanup clean --safe`) asks one question and then processes every category whose mode is `auto`, for items the policy does not rate dangerous. The default answer is no. Out of the box that is only `app-caches`; the other regenerable categories start in `review`, and you can switch the ones that go to quarantine to `auto` in the Categories tab. Native tool categories (`npm`, `yarn`, `pnpm`, `pip`, `brew`, `docker` and the rest) are never part of Clean safe or an automatic run.

**Clean selected** (`X`, or `--only`) processes exactly the categories you chose. In the interface, the dialog is where you consent; the engine is then started for just those categories. On the plain command line, `clean --only <ids>` asks one question per section it touches.

**Clean** with neither (`macos-cleanup clean`) walks the sections one by one, explains each, and asks. Review-tier categories always ask.

Before a mutating run the tool checks that no other mutating run is active (they exclude each other), warns when no recent backup is detected, and, with Full Disk Access missing, warns that the scan is partial.

## Command line

Every subcommand of `macos-cleanup` maps to one engine call. You can use the engine directly too: `bash cleanup_all.sh --cli ...` from the program folder.

| Command | Does | Read-only? |
|---------|------|------------|
| `macos-cleanup` | Interface on a terminal, or a plain dry run without one | yes |
| `macos-cleanup ui [tab]` | Interface on a tab | yes |
| `macos-cleanup scan [options]` | Dry run: measure and report | yes |
| `macos-cleanup plan [options]` | Measure and write a plan file | yes |
| `macos-cleanup clean [options]` | Interactive cleanup | no |
| `macos-cleanup clean --safe [options]` | The categories in mode `auto`, after one question | no |
| `macos-cleanup apply --from-plan FILE [options]` | Apply a plan you wrote earlier | no |
| `macos-cleanup restore RUN` | Restore a quarantine run (`RUN` is a run id, `latest` or a manifest file) | no |
| `macos-cleanup quarantine list` | List restore points | yes |
| `macos-cleanup quarantine purge SELECTOR` | Preview a purge. `SELECTOR` is `latest`, a run id, `all` or `expired` | yes |
| `macos-cleanup quarantine purge SELECTOR --apply` | Permanently remove those runs | no |
| `macos-cleanup history [--json] [--limit N]` | Past runs | yes |
| `macos-cleanup doctor [--json]` | Health checks | yes |
| `macos-cleanup schedule install\|remove\|status [--time HH:MM] [--weekday DAY] [--yes]` | Manage the automatic run. `install` shows what it will write and asks first (`--yes` skips the question). `status` is read-only | install and remove change a LaunchAgent file |
| `macos-cleanup migrate --preview\|--apply\|--undo MANIFEST` | Copy 3.x data to the new layout. `--preview` is read-only | `--apply` and `--undo` copy files |
| `macos-cleanup update-self [--check\|--rollback]` | Check for a newer release, install it, or go back to the previous version. Never runs by itself | `--check` is read-only |
| `macos-cleanup uninstall [--dry-run] [--purge-data]` | Remove the tool | `--dry-run` is read-only |
| `macos-cleanup version`, `macos-cleanup help` | Version and help | yes |

"Read-only" means it never changes your files. Every run still writes its own folder under the state directory.

### Engine flags

These work on `bash cleanup_all.sh` and, where they make sense, are passed through by the subcommands.

| Flag or mode | Read-only? | Meaning |
|--------------|-----------|---------|
| `--dry-run`, `analyze` | yes | Measure and report. Wins over any flag that would change things |
| `plan` | yes | Measure and write `plan.json` in the run folder |
| `apply --from-plan FILE` | no | Apply a plan. Safe items by default |
| `--interactive` | no | Ask per section |
| `--auto-safe` | no | The categories in mode `auto`, after one question |
| `--category NAME[,NAME]` | n/a | Limit to sections (`trash`, `user-caches`, `logs`, `system`, `dev`, `app-leftovers`, `time-machine`, `large-files`) or category ids |
| `--only ID[,ID]` | n/a | Limit to exactly these category ids. Works with every mode |
| `--include NAME` | n/a | Same as `--category` |
| `--exclude PATH` | n/a | Never touch this path (repeatable). Also reads `excludes.txt` |
| `--restore RUN\|FILE\|latest` | no | Restore from quarantine. With `--dry-run` it only previews what would go back and what would be skipped (add `--json` for JSON) |
| `--list-quarantine` | yes | List restore points. Add `--json` for JSON |
| `--purge-quarantine latest\|ID\|all\|expired` | preview | Preview a purge. Add `--apply` to do it. `--retention-days N` sets what counts as expired |
| `--apply` | no | Make a purge real |
| `--prune-artifacts` | no | Delete old run folders from the state directory. Never touches quarantine |
| `--quarantine` | n/a | Move removals into quarantine (the default) |
| `--permanent` | no | Delete for good instead, after the same checks. See the warning below |
| `--include-review` | n/a | Let `apply --from-plan` include review-tier items. Asks again per item |
| `--require-typing-path` | n/a | Make each review item of an `apply --from-plan` ask for its full path instead of yes or no |
| `--plan-file FILE` | n/a | Where `plan` writes the plan |
| `--non-interactive` | n/a | Never read from the terminal. Every question is answered no |
| `--yes` | n/a | With `--non-interactive`, approve safe categories only |
| `--unattended` | no | What the automatic run uses. Implies `--non-interactive --quarantine`. Refuses `--permanent`, `--include-review` and `--interactive` |
| `--json` | n/a | Print the run summary as JSON on standard output |
| `--redact` | n/a | Replace your home folder with `~`. Leave out user and host |
| `--plain`, `--quiet`, `--no-color`, `--log-level LEVEL`, `--lang CODE` | n/a | Output control |
| `--explain` | yes | Explain what the tool does and why |
| `--doctor` | yes | Health checks. Add `--json` for JSON |
| `--history` | yes | Past runs. Add `--json` for JSON |
| `--list-categories` | yes | Categories with tier and mode. Add `--json` for JSON, which also carries the last scan sizes |
| `--schedule install\|remove\|status`, `--time HH:MM` | install, remove | Manage the automatic run |
| `--cli` | n/a | Never open the interface |
| `--tui` | yes | Require the interface. Fails with exit code 2 without a terminal |
| `--version`, `--help` | yes | Version (`macos-cleanup 4.0.2`) and help |

**`--permanent` deletes for good.** Nothing can be restored. It is never used by an automatic run, and it is a setting you must choose on purpose (`remove_mode`). Even then, a folder that cannot be read completely is not deleted in permanent mode.

### Plans

`macos-cleanup plan` writes a plan file in the run folder. `apply --from-plan` only accepts a plan this tool wrote, on this Mac and for this user, less than 24 hours old, whose entries lie inside their category's allowed folders. A plan edited by hand, from another Mac or user, from 3.x, or too old is refused with exit code 2. The plan is signed with a key the tool keeps in its state folder. This guards against accidents. It is not protection against someone who already controls your account.

Apply never runs items rated dangerous. Review-tier items run only with `--include-review`, and each one is asked again (a yes or no question, or its full path with `--require-typing-path`). `sim-runtimes`, `docker` and `tm-snapshots` cannot be applied from a plan file at all and are skipped with the reason "plan rejected". Use an interactive run for those.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Done |
| 1 | The run finished but something failed, a check of `doctor` found a problem, or a restore or purge could not complete every entry. A restore that only skipped items whose original place is taken ends with a warning and also exits 1 |
| 2 | Wrong usage, refused option combination, invalid setting, refused plan, or `--tui` without a terminal |
| 3 | This macOS version is not supported |
| 130 | Interrupted |

## Settings

Settings live in `settings.conf` in the config folder, as `KEY=VALUE` lines. The file is read as plain data and never run as a script, and only the keys below are accepted. The interface edits the same file, so you can set a value there or edit the file.

Precedence, strongest first: command-line flag, `MACOS_CLEANUP_*` environment variable, an old-style environment variable (see [Environment variables](#environment-variables)), `settings.conf`, built-in default.

| Setting (key in `settings.conf`) | Values | Default | What it does |
|----------------------------------|--------|---------|--------------|
| `MACOS_CLEANUP_LANG` | `en`, `pl`, `de`, `es`, `fr`, `it`, `pt` | your system language if supported, else `en` | Interface and message language |
| `MACOS_CLEANUP_REMOVE_MODE` | `quarantine`, `permanent` | `quarantine` | Where removals go. `permanent` asks you to confirm in the interface |
| `MACOS_CLEANUP_QUARANTINE_RETENTION_DAYS` | 1 to 365 | 30 | How old a quarantine run must be to count as expired |
| `MACOS_CLEANUP_RECENT_DAYS` | 0 to 90 | 0 | Skip items changed in the last N days. 0 turns it off |
| `MACOS_CLEANUP_BACKUP_MAX_AGE_DAYS` | 1 to 90 | 14 | How old the latest backup may be before you get a warning |
| `MACOS_CLEANUP_REDACT` | `true`, `false` | `false` | Same as `--redact` for every run |
| `MACOS_CLEANUP_LOG_MAX_AGE_DAYS` | 1 to 365 | 30 | Minimum age for old logs |
| `MACOS_CLEANUP_DMG_MAX_AGE_DAYS` | 1 to 365 | 30 | Minimum age for installers in Downloads |
| `MACOS_CLEANUP_DEVICE_SUPPORT_MIN_AGE_DAYS` | 30 to 720 | 180 | Minimum age for iOS Device Support folders |
| `MACOS_CLEANUP_HOME_TOP_TIMEOUT` | 1 to 120 seconds | 20 | Time limit for the informational list of your largest home folders |
| `MACOS_CLEANUP_ARTIFACT_RETENTION_DAYS` | 0 to 365 | 30 | How long `--prune-artifacts` keeps run folders. 0 disables pruning |
| `MACOS_CLEANUP_SCHEDULE_TIME` | `HH:MM` | `10:30` | Time of day for the automatic run |
| `MACOS_CLEANUP_SCHEDULE_WEEKDAY` | `daily`, `mon` to `sun` | `sun` | Day of the automatic run |

The interface also keeps look settings (theme, accent, density, ASCII symbols, mouse, help panel, animation, automatic window resize, the default Dashboard action and the confirmation style) in `tui-settings.json`. Those never affect the engine.

While a search field has the focus (Categories, Settings) the whole row is highlighted and every key, digits included, types into it. `Esc` clears what you typed, a second `Esc` leaves the field, and the key line says which of the two it will do.

Settings tab actions: edit your exclude list, prune old run folders now, install or remove the automatic run, export, import, reset.

### Category modes (`category-modes.tsv`)

One line per category you changed, tab separated: `id`, `mode`, `source`. The mode is `auto`, `review` or `skip`. The Categories tab writes this file when you press `m`. You can also edit it by hand.

```
npm	skip	user
trash	review	user
```

### Your own rules (`rules.local.yaml`)

The shipped rules file rates paths as `safe`, `ask` or `never`. To change that for you, create `rules.local.yaml` in the config folder with the same layout. It can only make the tool more careful: it can raise a path from `safe` to `ask` or `never`, or add a `never` entry. It can never lower a rating. An invalid file is ignored with a warning, and the shipped rules apply.

### Excludes (`excludes.txt`)

One path per line. `~` is allowed and `#` starts a comment. Excluded paths are never touched, in any mode. `--exclude PATH` adds more for a single run.

```
# keep my build cache
~/Library/Caches/my-build-tool
```

## Quarantine lifecycle and restore

1. **Move.** A removal in quarantine mode is a rename into the quarantine folder, so it is fast and uses no extra space. This is why quarantine must be on the same disk as your home folder; if it is not, quarantine mode is refused.
2. **Record.** Each run gets its own folder named by run id. It holds the moved items, `manifest.tsv` (what came from where), `journal.jsonl` (what was moved, restored or purged in that run) and `run-info.json`.
3. **Restore.** `macos-cleanup restore RUN` puts items back where they came from. `RUN` is a run id, `latest` (the newest run that still has something to restore), or a manifest file. Restore refuses to write outside your home folder, onto protected paths, through symbolic links in parent folders, or from files outside the quarantine folder. An item whose original place is taken is skipped and stays in quarantine instead of being overwritten; the restore then ends with a warning and the command exits with 1.
4. **Emptied runs go away.** When a restore leaves no file in a quarantine run, the empty run folder is removed from the quarantine. The restore stays in History. A run with even one item left (for example one skipped because its place was taken) stays.
5. **Expire.** A run older than the retention period (default 30 days) is marked expired. Nothing is deleted automatically except by an automatic run's purge step.
6. **Purge.** `macos-cleanup quarantine purge SELECTOR --apply` removes the whole run folder, its manifest included. After a purge there is nothing left to restore from. Without `--apply` you only get a preview.

```bash
macos-cleanup quarantine list
macos-cleanup restore latest
macos-cleanup quarantine purge latest
macos-cleanup quarantine purge latest --apply
macos-cleanup quarantine purge expired --apply
```

`quarantine list` shows the manifest state per run: `ok`, `legacy` or `missing`. Runs created by 3.x stay restorable; see [MIGRATING_FROM_V3.md](MIGRATING_FROM_V3.md).

Quarantine is an undo for your last decisions, not a backup of your Mac.

## Honest space accounting

The tool shows two numbers and does not pretend they are one.

- **Estimated** is the sum of the sizes of the items the run was going to act on (for a scan or a preview, everything the scan found). Sizes are shown in binary units: KiB, MiB, GiB. It is an upper bound: it cannot see that APFS clones share blocks, so shared data can be counted more than once.
- **Measured** is the change in free space of your disk, sampled before the run and again after it. After a removal the tool waits a moment and samples again until two readings agree, because APFS gives space back asynchronously. Measured is shown only when it could be taken.

They often differ, and the result card says why:

- **Quarantine frees nothing.** Moving a file within the disk does not release its blocks. Space comes back when you purge.
- **Local snapshots keep deleted blocks.** Time Machine and system snapshots hold on to data that no longer exists in your files. The tool shows how many snapshots you have next to the measured figure.
- **Clones share blocks.** Deleting one copy of a cloned file frees little or nothing while the other copy exists.
- **APFS reclaims space late.** Free space can keep rising for a while after a purge.
- **Purgeable space.** macOS can mark some space as purgeable. The tool shows it only when `diskutil` reports it, which depends on your macOS version.

An estimate for a scan that could not read everything is marked partial and is a lower bound for those folders.

A scan never waits for one stuck tool. Every external program it runs (size measurements, `find`, `df`, `diskutil`, `mdfind`, the package managers, `brew`, `docker`, `tmutil`, `xcrun`) has a time limit, and a lookup that times out counts as "not measured", never as 0 bytes. The seconds each category took are recorded in the run's `engine.log` (`scan time: <category> <seconds>s`) and in its events.

## Full Disk Access

macOS hides some folders (Safari data, Mail, Messages and others) from programs that do not have Full Disk Access. The tool has no way to ask macOS whether it has access, so it checks a few protected locations by listing their names, never reading file contents: `~/Library/Mail`, `~/Library/Safari`, `~/Library/Application Support/com.apple.TCC` and, as a weaker hint, `~/Library/Containers` (only the list of names). The result is `granted`, `denied` or `unknown`. It never opens the private folders inside other apps' containers, because that makes macOS show a consent alert.

When access is missing, the tool warns once, marks the scan partial, and carries on. It never tries to get around the restriction. A folder it cannot fully read is never deleted in permanent mode.

To grant access: open System Settings, go to Privacy & Security, then Full Disk Access, and add your terminal app. In the interface, Diagnostics then `F` opens that pane. Restart the terminal afterwards. Full Disk Access is optional: the tool works without it, with less complete numbers.

## Automatic runs

Off by default. The installer never turns them on.

```bash
macos-cleanup schedule install --time 10:30
macos-cleanup schedule status
macos-cleanup schedule remove
```

This writes `~/Library/LaunchAgents/com.github.kasprowiczm.macos-cleanup.plist`. The weekday comes from `--weekday` or the `MACOS_CLEANUP_SCHEDULE_WEEKDAY` setting (default Sunday); the time from `--time` or `MACOS_CLEANUP_SCHEDULE_TIME`. `install` shows what it will write and asks first; `--yes` skips the question. If your Mac is asleep at that time, the run happens when it wakes. It runs at low priority.

A scheduled run does only this:

1. Moves items into quarantine, only from categories whose mode is `auto` (out of the box only `app-caches`) that are marked for unattended use, and never items rated dangerous.
2. Purges quarantine runs past their retention period.

It never runs a native tool (`npm`, `pnpm`, `pip`, `brew`, `docker`, `simctl`, `tmutil`), never touches the review tier, never uses permanent mode and never asks a question. It leaves a normal run in History. Because it can touch files unattended, turn it on only after you have used the tool by hand.

## Troubleshooting

| Problem | What to do |
|---------|-----------|
| `macos-cleanup: command not found` | Open a new terminal. Check that `~/.local/bin` is in your `PATH`. Run the installer again if needed |
| Typing `macos-cleanup` or `mac-cleanup` starts a different program | Another program earlier on your `PATH` has that name (the installer names the file). Remove or rename it, or run `~/.local/bin/macos-cleanup` by its full path |
| The interface does not open | It needs a terminal, `TERM` other than `dumb`, and Python 3.9 or later. `macos-cleanup scan` works without it. `--tui` exits with 2 when it cannot start |
| "Another run is active" | Mutating runs exclude each other, including a 3.x run. Wait for it to finish. A lock left by a crashed run is recovered automatically |
| The scan says "partial" | Some folders could not be read. See [Full Disk Access](#full-disk-access) |
| Measured is much lower than estimated | See [Honest space accounting](#honest-space-accounting). Check `macos-cleanup quarantine list` and `macos-cleanup doctor` for snapshots |
| A category was skipped with a reason | The reason is in the report. `in_use` means the owner program was running; `too_recent` means the item changed within your minimum age; `needs_permanent` means it is outside your home folder; `protected_path` means it is on the protected list |
| Plan refused | The plan is too old, from 3.x, edited, or from another Mac or user. Run `macos-cleanup plan` again |
| A setting is ignored | A relative path in a `MACOS_CLEANUP_*` variable is an error (exit 2). Values in `settings.conf` outside the table above are ignored |
| Quarantine mode is refused | The quarantine folder is on a different disk than your home folder. Move it back with `MACOS_CLEANUP_QUARANTINE_DIR` |
| I want to see everything the tool knows | `macos-cleanup doctor` |

Where reports are: each run has a folder under `~/.local/state/macos-cleanup/runs/<run id>/` with `report.md`, `run.json`, `plan.json`, `journal.jsonl` and `engine.log`. In the interface, History then `o` shows that folder in Finder.

## Environment variables

Settings and overrides use the `MACOS_CLEANUP_` prefix. Path overrides must be absolute.

| Variable | Meaning |
|----------|---------|
| `MACOS_CLEANUP_HOME` | Program folder |
| `MACOS_CLEANUP_CONFIG_DIR` | Settings folder |
| `MACOS_CLEANUP_STATE_DIR` | State folder |
| `MACOS_CLEANUP_QUARANTINE_DIR` | Quarantine folder. Its last component must be `quarantine` |
| `MACOS_CLEANUP_LEGACY_DIR` | Where `migrate` looks for a 3.x folder |
| `MACOS_CLEANUP_LANG` and the other setting names | See [Settings](#settings) |

Old names still read in 4.x: `LANG_CODE`, `QUARANTINE_ROOT`, `ARTIFACT_RETENTION_DAYS`, `HOME_TOP_DIRS_TIMEOUT`, `LOGS_DIR`, `REPORTS_DIR`, `RULES_FILE`. `LOGS_DIR` and `REPORTS_DIR` are deprecated and are logged when used. `AUTO_YES` and `REMOVE_MODE` from the environment are ignored with one warning, because consent now comes only from flags and `settings.conf`. `NON_INTERACTIVE` is still honoured with a deprecation note, since it can only make a run less interactive.
