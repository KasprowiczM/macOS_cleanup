#!/usr/bin/env python3
"""Copy the run data of a v3 checkout into the v4 folders (macos-cleanup migrate).

Explicit and reversible. Nothing here runs by itself.

    layout_migrate.py --preview            show what would be copied, change nothing (default)
    layout_migrate.py --apply              copy it, with a backup and a manifest
    layout_migrate.py --undo MANIFEST      take back what --apply created

The v3 checkout is only ever read: it is never changed, renamed or deleted.
Nothing is ever moved; every file is a copy, so disk use grows by the size of
the logs and reports only.

What is copied (always as copies):

    logs/cleanup_<run>.log            -> <state>/runs/<run>/engine.log
    reports/report_<run>.md           -> <state>/runs/<run>/report.md
    reports/plan_<run>.json           -> <state>/runs/<run>/plan.json
    reports/journal_<run>.jsonl       -> <state>/runs/<run>/journal.jsonl
    (and a minimal <state>/runs/<run>/run.json with "legacy": true, so History lists the run)
    reports/restore_<run>.tsv         -> <quarantine>/<run>/manifest.tsv      when that quarantine
                                         run exists and has no manifest yet, so old runs stay
                                         restorable
                                      -> <state>/legacy/reports/restore_<run>.tsv   otherwise
                                         (an orphan; it is reported and never deleted)
    cleanup_rules.yaml                -> <config>/rules.local.yaml.from-v3    only when it differs
                                         from the shipped 3.0.7 copy; it is NOT active, review it

Plans written by 3.x carry no HMAC and are refused by `apply --from-plan`; they are
copied only so the History tab can show them.

A destination that already exists with different content is a conflict: it is left
alone unless --overwrite is given, and then the old file is backed up first. A
quarantine manifest that already exists is authoritative and is never replaced.
Every apply writes <state>/backups/layout-<timestamp>/manifest.json (sha256 of each
file) plus copies of anything it overwrote. Undo removes only files it created whose
sha256 still matches, and restores anything it overwrote from the backup.

Exit codes: 0 done or nothing to do, 1 failed or refused, 2 bad usage or bad path setting.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time

FORMAT = "macos-cleanup-layout-migration"
NAME = "macos-cleanup"
MAX_BYTES = 64 * 1024 * 1024
RUN_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{6}_\d+$")
# sha256 of cleanup_rules.yaml as shipped in release 3.0.7; a v3 file with this digest is unedited.
SHIPPED_RULES_SHA256 = ("02916d530ea51831a212a950e37fc70447c49184e37c930a60e7859492111469",)
LEGACY_DEFAULT_DIR = ("Dev_Env", "macOS_cleanup")


class MigrateError(Exception):
    """One sentence, ready to print. Exit 1."""


class UsageError(Exception):
    """A bad option or path setting. Exit 2."""


# ---------------------------------------------------------------- paths
# Same precedence as the program's own resolver (lib/paths.sh, mc_paths.py); kept
# here so the migration needs nothing but this file and works from any checkout.

def _clean(path):
    return path.rstrip("/") or "/"


def _override(env, name):
    value = env.get(name, "")
    if not value:
        return None
    if not value.startswith("/"):
        raise UsageError("%s must be an absolute path." % name)
    return _clean(value)


def _xdg(env, name):
    value = env.get(name, "")
    return _clean(value) if value.startswith("/") else None


def resolve_paths(env):
    home = env.get("HOME", "")
    if not home:
        raise UsageError("HOME is not set, so the folders cannot be located.")
    if not home.startswith("/"):
        raise UsageError("HOME must be an absolute path.")
    home = _clean(home)
    config = _override(env, "MACOS_CLEANUP_CONFIG_DIR") or \
        (_xdg(env, "XDG_CONFIG_HOME") or home + "/.config") + "/" + NAME
    state = _override(env, "MACOS_CLEANUP_STATE_DIR") or \
        (_xdg(env, "XDG_STATE_HOME") or home + "/.local/state") + "/" + NAME
    quarantine = _override(env, "MACOS_CLEANUP_QUARANTINE_DIR") or _override(env, "QUARANTINE_ROOT") or \
        home + "/Library/Application Support/macOS_cleanup/quarantine"
    parts = quarantine.split("/")
    if "." in parts or ".." in parts or parts[-1] != "quarantine":
        raise UsageError("The quarantine folder must be an absolute path without . or .. parts "
                         "whose last part is named quarantine.")
    return {"home": home, "config": config, "state": state, "quarantine": quarantine}


# ---------------------------------------------------------------- helpers

def _sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def _atomic_write(dest, data=None, src=None, mode=0o600):
    """Write dest via a temp file in the same folder and an atomic rename."""
    folder = os.path.dirname(dest)
    fd, tmp = tempfile.mkstemp(prefix=".migrate-", dir=folder)
    try:
        with os.fdopen(fd, "wb") as out:
            if src is not None:
                with open(src, "rb") as handle:
                    shutil.copyfileobj(handle, out)
            else:
                out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, dest)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _write_json(path, value):
    _atomic_write(path, data=(json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8"))


def _is_legacy_checkout(path):
    return bool(path) and os.path.isdir(path) and os.path.isfile(os.path.join(path, "cleanup_all.sh"))


def _legacy_version(path):
    """Version of a checkout (VERSION file, else SCRIPT_VERSION of a v3 one), or 3 when unreadable."""
    try:
        with open(os.path.join(path, "VERSION"), encoding="utf-8") as handle:
            text = handle.read().strip()
            if text:
                return text
    except OSError:
        pass
    try:
        with open(os.path.join(path, "config", "defaults.sh"), encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = re.match(r'\s*(?:readonly\s+)?SCRIPT_VERSION="([^"]+)"', line)
                if match:
                    return match.group(1)
    except OSError:
        pass
    return "3"


def _now():
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def _inside(path, parent):
    parent = parent.rstrip("/")
    return path == parent or path.startswith(parent + "/")


def toolkit_root():
    return os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def find_source(explicit, env):
    """The v3 checkout: --source, else $MACOS_CLEANUP_LEGACY_DIR, else ~/Dev_Env/macOS_cleanup,
    else the checkout this script lives in."""
    if explicit:
        if not _is_legacy_checkout(explicit):
            raise UsageError("%s does not look like a macOS Cleanup folder (cleanup_all.sh is missing)." % explicit)
        return os.path.realpath(explicit)
    candidates = []
    if env.get("MACOS_CLEANUP_LEGACY_DIR"):
        candidates.append(env["MACOS_CLEANUP_LEGACY_DIR"])
    else:
        candidates.append(os.path.join(env.get("HOME", ""), *LEGACY_DEFAULT_DIR))
        root = toolkit_root()
        if os.path.exists(os.path.join(root, ".git")):
            candidates.append(root)
    for candidate in candidates:
        if _is_legacy_checkout(candidate):
            return os.path.realpath(candidate)
    return None


# ---------------------------------------------------------------- planning

def _regular(path):
    return os.path.isfile(path) and not os.path.islink(path)


def _list(folder, prefix, suffix):
    """[(run_id, path)] for <folder>/<prefix><run><suffix>, sorted by run id."""
    found = []
    if not os.path.isdir(folder):
        return found
    for name in sorted(os.listdir(folder)):
        if not (name.startswith(prefix) and name.endswith(suffix)):
            continue
        run = name[len(prefix):len(name) - len(suffix)] if suffix else name[len(prefix):]
        if RUN_RE.match(run):
            found.append((run, os.path.join(folder, name)))
    return found


def build_plan(source, paths, overwrite=False, shipped=SHIPPED_RULES_SHA256):
    """Return a list of entry dicts. action is one of copy, create, overwrite, same, conflict, skip."""
    entries = []
    roots = {"state": paths["state"], "config": paths["config"], "quarantine": paths["quarantine"]}

    def add(kind, root, rel, src=None, data=None, note="", protected=False):
        dest = os.path.join(roots[root], rel)
        entry = {"kind": kind, "root": root, "src": src, "dest": dest, "rel": "%s/%s" % (root, rel), "note": note,
                 "action": "copy", "sha256_src": None, "sha256_before": None, "data": data, "protected": protected}
        if data is not None:
            entry["sha256_src"] = _sha256_bytes(data)
            entry["action"] = "create"
        else:
            if os.path.islink(src):
                entry.update(action="skip", note="it is a link")
                entries.append(entry)
                return entry
            if not os.path.isfile(src):
                return None
            if os.path.getsize(src) > MAX_BYTES:
                entry.update(action="skip", note="it is larger than 64 MB")
                entries.append(entry)
                return entry
            entry["sha256_src"] = _sha256(src)
        if os.path.islink(dest):
            entry.update(action="skip", note="the destination is a link")
        elif os.path.exists(dest):
            if not os.path.isfile(dest):
                entry.update(action="skip", note="the destination is not a file")
            else:
                entry["sha256_before"] = _sha256(dest)
                if entry["sha256_before"] == entry["sha256_src"]:
                    entry["action"] = "same"
                elif protected:
                    entry.update(action="conflict", note="the quarantine run already has its own manifest, which is authoritative")
                elif overwrite:
                    entry["action"] = "overwrite"
                else:
                    entry["action"] = "conflict"
        entries.append(entry)
        return entry

    logs = os.path.join(source, "logs")
    reports = os.path.join(source, "reports")
    run_files = {}
    for run, src in _list(logs, "cleanup_", ".log"):
        run_files.setdefault(run, []).append(("engine.log", src))
    for prefix, suffix, target in (("report_", ".md", "report.md"), ("plan_", ".json", "plan.json"),
                                   ("journal_", ".jsonl", "journal.jsonl")):
        for run, src in _list(reports, prefix, suffix):
            run_files.setdefault(run, []).append((target, src))
    version = _legacy_version(source)
    for run in sorted(run_files):
        copied = 0
        for target, src in run_files[run]:
            entry = add("run-" + target.split(".")[0], "state", "runs/%s/%s" % (run, target), src=src)
            if entry is not None and entry["action"] in ("copy", "same"):
                copied += 1
        summary = os.path.join(roots["state"], "runs", run, "run.json")
        if copied and not os.path.lexists(summary):
            stamp = "%s-%s-%sT%s:%s:%s" % (run[0:4], run[5:7], run[8:10], run[11:13], run[13:15], run[15:17])
            body = {"schema_version": "2.0", "tool": NAME, "version": version, "run_id": run, "mode": "legacy",
                    "legacy": True, "dry_run": None, "started_at": stamp, "result": "unknown",
                    "note": "Imported from a v3 checkout by macos-cleanup migrate; no run summary existed."}
            add("run-summary", "state", "runs/%s/run.json" % run,
                data=(json.dumps(body, indent=2, sort_keys=True) + "\n").encode("utf-8"))

    for run, src in _list(reports, "restore_", ".tsv"):
        run_dir = os.path.join(roots["quarantine"], run)
        if os.path.isdir(run_dir) and not os.path.islink(run_dir):
            add("restore-manifest", "quarantine", "%s/manifest.tsv" % run, src=src, protected=True,
                note="keeps that quarantine run restorable")
        else:
            add("restore-orphan", "state", "legacy/reports/restore_%s.tsv" % run, src=src,
                note="orphan: no quarantine run of that name exists any more")

    rules = os.path.join(source, "cleanup_rules.yaml")
    if _regular(rules):
        if _sha256(rules) in shipped:
            entries.append({"kind": "rules", "root": "config", "src": rules, "rel": "config/rules.local.yaml.from-v3",
                            "dest": os.path.join(roots["config"], "rules.local.yaml.from-v3"), "action": "skip",
                            "data": None, "note": "it matches the shipped 3.0.7 copy", "sha256_src": None,
                            "sha256_before": None, "protected": False})
        else:
            add("rules", "config", "rules.local.yaml.from-v3", src=rules,
                note="your edited rules; not active, review them before renaming")
    return entries


def _describe(entry):
    action, rel, note = entry["action"], entry["rel"], entry.get("note", "")
    src = os.path.basename(entry["src"]) if entry["src"] else entry["kind"]
    if action in ("copy", "create"):
        extra = " (%s)" % note if note else ""
        return "copy      %s -> %s%s" % (src, rel, extra)
    if action == "overwrite":
        return "replace   %s -> %s (the existing file is backed up first)" % (src, rel)
    if action == "same":
        return "same      %s is already in place" % rel
    if action == "conflict":
        if entry.get("protected"):
            return "keeps     %s: %s" % (rel, note)
        return "differs   %s already exists with other content; it stays unless you add --overwrite" % rel
    return "skip      %s: %s" % (os.path.basename(entry["src"] or rel), note)


def _print_entries(plan, out, skip_actions=None):
    for entry in plan:
        if skip_actions is not None and entry["action"] not in skip_actions:
            continue
        if entry["action"] == "skip" and entry.get("note") == "it matches the shipped 3.0.7 copy":
            print("  skip      cleanup_rules.yaml matches the shipped 3.0.7 copy and is not needed", file=out)
            continue
        print("  " + _describe(entry), file=out)


# ---------------------------------------------------------------- commands

TODO = ("copy", "create", "overwrite")


def cmd_preview(source, paths, args, out):
    plan = build_plan(source, paths, args.overwrite, tuple(args.shipped_sha256) or SHIPPED_RULES_SHA256)
    print("Found a v3 checkout: %s (version %s)." % (source, _legacy_version(source)), file=out)
    print("Run data goes to %s; restore manifests to %s." % (paths["state"], paths["quarantine"]), file=out)
    if not plan:
        print("There is no run data to bring over.", file=out)
        return 0
    _print_entries(plan, out)
    todo = [e for e in plan if e["action"] in TODO]
    orphans = [e for e in plan if e["kind"] == "restore-orphan" and e["action"] in TODO + ("same",)]
    if orphans:
        print("%d restore manifest(s) have no quarantine run and go to %s/legacy/reports; they are never deleted."
              % (len(orphans), paths["state"]), file=out)
    if todo:
        print("Nothing was changed. Run with --apply to copy these %d file(s); your v3 folder is never "
              "deleted and --undo takes the copies back." % len(todo), file=out)
    else:
        print("Nothing would change.", file=out)
    return 0


def _make_dirs(folder, created):
    """mkdir -p with mode 0700 for every folder created; records them."""
    missing = []
    probe = folder
    while not os.path.isdir(probe) and probe != os.path.dirname(probe):
        missing.append(probe)
        probe = os.path.dirname(probe)
    for directory in reversed(missing):
        os.mkdir(directory, 0o700)
        os.chmod(directory, 0o700)
        created.append(directory)


def cmd_apply(source, paths, args, out):
    plan = build_plan(source, paths, args.overwrite, tuple(args.shipped_sha256) or SHIPPED_RULES_SHA256)
    todo = [e for e in plan if e["action"] in TODO]
    _print_entries(plan, out, skip_actions=("conflict", "skip"))
    if not todo:
        print("Nothing to do: everything is already in place.", file=out)
        return 0

    state = paths["state"]
    config_existed = os.path.isdir(paths["config"])
    created_dirs = []
    _make_dirs(state, created_dirs)
    stamp = _now()
    backup_dir = os.path.join(state, "backups", "layout-" + stamp)
    suffix = 0
    while os.path.exists(backup_dir):
        suffix += 1
        backup_dir = os.path.join(state, "backups", "layout-%s-%d" % (stamp, suffix))
    _make_dirs(os.path.join(backup_dir, "files"), created_dirs)
    manifest_path = os.path.join(backup_dir, "manifest.json")
    args.manifest_path = manifest_path

    records = []
    for index, entry in enumerate(todo):
        record = {"kind": entry["kind"], "root": entry["root"], "src": entry["src"], "dest": entry["dest"],
                  "rel": entry["rel"], "action": entry["action"], "sha256_src": entry["sha256_src"],
                  "sha256_before": entry["sha256_before"], "sha256_after": None, "backup": None}
        if entry["action"] == "overwrite":
            record["backup"] = "files/%d-%s" % (index, os.path.basename(entry["dest"]))
            shutil.copy2(entry["dest"], os.path.join(backup_dir, record["backup"]))
            if _sha256(os.path.join(backup_dir, record["backup"])) != entry["sha256_before"]:
                raise MigrateError("A backup copy did not verify, so nothing was changed.")
        records.append(record)
    manifest = {"format": FORMAT, "format_version": 1, "status": "in_progress", "created": stamp,
                "source": source, "roots": {"state": state, "config": paths["config"],
                                            "quarantine": paths["quarantine"]},
                "toolkit_version": _legacy_version(toolkit_root()), "entries": records, "created_dirs": [],
                "config_created": False}
    _write_json(manifest_path, manifest)

    for entry, record in zip(todo, records):
        folder = os.path.dirname(entry["dest"])
        _make_dirs(folder, created_dirs)
        if entry["data"] is not None:
            _atomic_write(entry["dest"], data=entry["data"])
        else:
            _atomic_write(entry["dest"], src=entry["src"])
        record["sha256_after"] = _sha256(entry["dest"])
        if record["sha256_after"] != entry["sha256_src"]:
            raise MigrateError("%s did not copy correctly; run --undo %s to take the copies back."
                               % (entry["rel"], manifest_path))
        manifest["created_dirs"] = created_dirs
        manifest["config_created"] = (not config_existed) and os.path.isdir(paths["config"])
        _write_json(manifest_path, manifest)
    manifest["status"] = "applied"
    _write_json(manifest_path, manifest)
    print("Copied %d file(s)." % len(todo), file=out)
    print("Manifest and backups: %s" % backup_dir, file=out)
    print("To undo: macos-cleanup migrate --undo %s" % manifest_path, file=out)
    print("Your v3 folder %s was not changed." % source, file=out)
    return 0


def _load_manifest(arg):
    path = arg
    if os.path.isdir(path):
        path = os.path.join(path, "manifest.json")
    try:
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError):
        raise MigrateError("The manifest %s cannot be read." % arg)
    if not isinstance(manifest, dict) or manifest.get("format") != FORMAT \
            or not isinstance(manifest.get("entries"), list) or not isinstance(manifest.get("roots"), dict):
        raise MigrateError("%s is not a macos-cleanup migration manifest." % arg)
    return os.path.realpath(path), manifest


def cmd_undo(arg, args, out):
    manifest_path, manifest = _load_manifest(arg)
    if manifest.get("status") == "undone":
        print("This migration was already undone.", file=out)
        return 0
    backup_dir = os.path.dirname(manifest_path)
    roots = {}
    for name in ("state", "config", "quarantine"):
        value = manifest["roots"].get(name)
        if not isinstance(value, str) or not value.startswith("/") or os.path.realpath(value) == "/":
            raise MigrateError("The manifest names no usable %s folder." % name)
        roots[name] = os.path.realpath(value)

    plans = []
    problems = []
    for entry in manifest["entries"]:
        dest = entry.get("dest")
        real = os.path.realpath(dest) if isinstance(dest, str) else ""
        if not real or not any(_inside(real, root) and real != root for root in roots.values()):
            raise MigrateError("The manifest lists a file outside the macos-cleanup folders, so it will not be used.")
        expected = entry.get("sha256_after") or entry.get("sha256_src")
        before = entry.get("sha256_before")
        exists = os.path.isfile(dest) and not os.path.islink(dest)
        current = _sha256(dest) if exists else None
        action = entry.get("action")
        if os.path.lexists(dest) and not exists:
            problems.append("%s is no longer a regular file" % entry.get("rel", dest))
            continue
        if action in ("copy", "create"):
            if current is None or current == expected:
                plans.append(("remove", dest, None))
            else:
                problems.append("%s changed after the migration" % entry.get("rel", dest))
        elif action == "overwrite":
            backup = entry.get("backup")
            backup_file = os.path.realpath(os.path.join(backup_dir, backup)) if isinstance(backup, str) else None
            if backup_file is None or not _inside(backup_file, os.path.realpath(backup_dir)) or not os.path.isfile(backup_file):
                problems.append("the backup of %s is missing" % entry.get("rel", dest))
            elif _sha256(backup_file) != before:
                problems.append("the backup of %s no longer matches" % entry.get("rel", dest))
            elif current == before:
                continue  # the write never happened
            elif current == expected:
                plans.append(("restore", dest, backup_file))
            else:
                problems.append("%s changed after the migration" % entry.get("rel", dest))
        else:
            raise MigrateError("The manifest holds an action this version does not understand.")
    if problems and not args.force:
        raise MigrateError("Undo stopped and changed nothing: %s. Restore those files by hand or pass --force." %
                           "; ".join(problems))

    for kind, dest, backup_file in plans:
        if kind == "remove":
            if os.path.lexists(dest):
                os.unlink(dest)
        else:
            _atomic_write(dest, src=backup_file)
    for folder in sorted(manifest.get("created_dirs", []), key=len, reverse=True):
        real = os.path.realpath(folder)
        # only folders the migration itself created, and only below a known root or on the way to one
        known = any((_inside(real, root) and real != root) or _inside(root, real) for root in roots.values())
        if known and not _inside(real, os.path.realpath(backup_dir)):
            try:
                os.rmdir(folder)
            except OSError:
                pass
    if manifest.get("config_created"):
        try:
            os.rmdir(roots["config"])
        except OSError:
            pass
    manifest["status"] = "undone"
    manifest["undone"] = _now()
    _write_json(manifest_path, manifest)
    print("Undone: %d file(s) restored or removed. Your v3 folder was never touched." % len(plans), file=out)
    return 0


def main(argv=None, out=None, env=None):
    out = out or sys.stdout
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(prog="macos-cleanup migrate",
                                     description="Copy the run data of a v3 checkout into the v4 folders.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--preview", action="store_true", help="show what would be copied (default)")
    group.add_argument("--apply", action="store_true", help="copy it, with backup and manifest")
    group.add_argument("--undo", metavar="MANIFEST", help="take back an --apply from its manifest.json (or its folder)")
    parser.add_argument("--source", help="the v3 checkout (default: $MACOS_CLEANUP_LEGACY_DIR, ~/Dev_Env/macOS_cleanup, "
                                         "then this checkout)")
    parser.add_argument("--overwrite", action="store_true",
                        help="replace differing files in the new folders after backing them up")
    parser.add_argument("--force", action="store_true", help="with --undo: continue even if a file changed since")
    parser.add_argument("--shipped-sha256", action="append", default=[], metavar="HEX",
                        help="extra sha256 of an unedited cleanup_rules.yaml (repeatable)")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return 0 if exc.code == 0 else 2
    args.manifest_path = None
    for value in args.shipped_sha256:
        if not re.fullmatch(r"[0-9a-fA-F]{64}", value):
            print("--shipped-sha256 needs a 64-digit hex value.", file=sys.stderr)
            return 2
    args.shipped_sha256 = [v.lower() for v in args.shipped_sha256]
    if args.shipped_sha256:
        args.shipped_sha256 = list(SHIPPED_RULES_SHA256) + args.shipped_sha256
    try:
        if args.undo:
            return cmd_undo(args.undo, args, out)
        paths = resolve_paths(env)
        source = find_source(args.source, env)
        if not source:
            print("No v3 checkout was found, so there is nothing to migrate. "
                  "If it lives somewhere unusual, pass --source FOLDER.", file=out)
            return 0
        if args.apply:
            return cmd_apply(source, paths, args, out)
        return cmd_preview(source, paths, args, out)
    except UsageError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    except MigrateError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except OSError as exc:
        hint = " Use --undo %s to take back what was copied." % args.manifest_path if args.manifest_path else ""
        print("The migration stopped because of a file problem (%s). Nothing further was changed.%s"
              % (exc.strerror or exc.__class__.__name__, hint), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
