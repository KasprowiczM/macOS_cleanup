from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any

from dev_sync_core import (
    ConfigReviewRequired,
    DevSyncError,
    MANIFEST_FILENAME,
    QUARANTINE_DIRNAME,
    Logger,
    RunOptions,
    classify_repo,
    lexists,
    load_config,
    normalize_relpath,
    path_is_under_roots,
    read_manifest,
    resolve_under_leaf,
    require_local_provider,
    safe_relpath,
    should_keep_path,
    walk_files,
)


PROTECTED_PATTERNS = [
    ".dev_sync_config.json",
    ".env",
    ".env.*",
    ".dev.vars",
    ".dev.vars.*",
    ".claude/settings.local.json",
    ".gemini/settings.local.json",
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "*.crt",
    "*.cer",
    "secrets/",
    ".ssh/",
]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Plan and quarantine generated, excluded, stale, or Git-tracked files from the cloud overlay."
    )
    parser.add_argument("--plan-out", help="Write a JSON cleanup plan. No files are changed.")
    parser.add_argument("--apply-plan", help="Quarantine exactly the candidates from a saved JSON plan.")
    parser.add_argument("--apply", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--quarantine-dir", default=QUARANTINE_DIRNAME, help="Quarantine directory under provider root.")
    parser.add_argument("--verbose", action="store_true", help="Emit extra diagnostic output.")
    return parser


def rel_matches_pattern(relpath: str, pattern: str, *, is_dir: bool = False) -> bool:
    rel = normalize_relpath(relpath)
    if not rel:
        return False
    patt = pattern.strip()
    if patt.endswith("/"):
        segment_pattern = patt.rstrip("/")
        parts = rel.split("/")
        directory_segments = parts if is_dir else parts[:-1]
        return any(fnmatch.fnmatch(segment, segment_pattern) for segment in directory_segments)
    return (
        fnmatch.fnmatch(rel, patt)
        or fnmatch.fnmatch(Path(rel).name, patt)
        or any(fnmatch.fnmatch(segment, patt) for segment in rel.split("/"))
    )


def is_protected_relpath(relpath: str, *, is_dir: bool = False) -> bool:
    return any(rel_matches_pattern(relpath, pattern, is_dir=is_dir) for pattern in PROTECTED_PATTERNS)


def topmost_relpaths(relpaths: set[str]) -> list[str]:
    selected: list[str] = []
    for rel in sorted(relpaths, key=lambda item: (item.count("/"), item)):
        if any(path_is_under_roots(rel, [parent]) for parent in selected):
            continue
        selected.append(rel)
    return selected


def note_candidate(candidates: dict[str, set[str]], relpath: str, reason: str) -> None:
    rel = normalize_relpath(relpath)
    if rel and rel != MANIFEST_FILENAME and not rel.startswith(QUARANTINE_DIRNAME + "/"):
        candidates.setdefault(rel, set()).add(reason)


def collect_prune_candidates(
    base: Path,
    config,
    *,
    manifest_files: set[str] | None,
) -> dict[str, set[str]]:
    if not base.exists():
        return {}

    candidates: dict[str, set[str]] = {}
    exclude_patterns = config.exclude_patterns or []
    include_always = config.include_always or []

    for current, dirnames, filenames in os.walk(base, topdown=True, followlinks=False):
        current_path = Path(current)
        rel_dir = "" if current_path == base else current_path.relative_to(base).as_posix()

        kept_dirnames: list[str] = []
        for dirname in dirnames:
            rel = dirname if not rel_dir else f"{rel_dir}/{dirname}"
            if rel == QUARANTINE_DIRNAME:
                continue
            if manifest_files is not None and rel not in manifest_files and not any(
                path_is_under_roots(path, [rel]) for path in manifest_files
            ):
                note_candidate(candidates, rel, "not-in-current-manifest")
                continue
            if not should_keep_path(rel, exclude_patterns, include_always, is_dir=True):
                note_candidate(candidates, rel, "excluded-generated-or-template")
                continue
            if (current_path / dirname).is_symlink():
                continue
            kept_dirnames.append(dirname)
        dirnames[:] = kept_dirnames

        for filename in filenames:
            rel = filename if not rel_dir else f"{rel_dir}/{filename}"
            if rel == MANIFEST_FILENAME:
                continue
            if manifest_files is not None and rel not in manifest_files:
                note_candidate(candidates, rel, "not-in-current-manifest")
                continue
            if not should_keep_path(rel, exclude_patterns, include_always):
                note_candidate(candidates, rel, "excluded-generated-or-template")

    compacted: dict[str, set[str]] = {}
    for rel in topmost_relpaths(set(candidates)):
        compacted[rel] = candidates[rel]
    return compacted


def protected_descendants(path: Path, relpath: str) -> list[str]:
    if not lexists(path):
        return []

    rel = normalize_relpath(relpath)
    protected: list[str] = []
    if path.is_dir() and not path.is_symlink():
        for current, dirnames, filenames in os.walk(path, topdown=True, followlinks=False):
            current_path = Path(current)
            rel_dir = rel if current_path == path else f"{rel}/{current_path.relative_to(path).as_posix()}"
            for dirname in dirnames:
                child_rel = f"{rel_dir}/{dirname}"
                if is_protected_relpath(child_rel, is_dir=True):
                    protected.append(child_rel)
            for filename in filenames:
                child_rel = f"{rel_dir}/{filename}"
                if is_protected_relpath(child_rel):
                    protected.append(child_rel)
    elif is_protected_relpath(rel):
        protected.append(rel)

    return sorted(protected)


def local_storage_size(path: Path) -> tuple[int, int]:
    if not lexists(path):
        return 0, 0
    logical = 0
    blocks = 0
    if path.is_dir() and not path.is_symlink():
        for current, dirnames, filenames in os.walk(path, topdown=True, followlinks=False):
            current_path = Path(current)
            for name in [*dirnames, *filenames]:
                child = current_path / name
                try:
                    stat = child.lstat()
                except OSError:
                    continue
                logical += stat.st_size
                blocks += getattr(stat, "st_blocks", 0) * 512
    else:
        stat = path.lstat()
        logical = stat.st_size
        blocks = getattr(stat, "st_blocks", 0) * 512
    return logical, blocks


def build_plan(root: Path, config, provider_root: Path, logger: Logger) -> dict[str, Any]:
    manifest_files = read_manifest(provider_root)
    candidates = collect_prune_candidates(provider_root, config, manifest_files=manifest_files)

    tracked = classify_repo(root, config).tracked_files
    for rel in walk_files(provider_root):
        if rel in tracked:
            note_candidate(candidates, rel, "tracked-by-git")

    entries: list[dict[str, Any]] = []
    for rel, reasons in sorted(candidates.items()):
        rel = safe_relpath(rel)
        path = provider_root / rel
        logical, physical = local_storage_size(path)
        protected = protected_descendants(path, rel)
        entries.append(
            {
                "base": str(provider_root),
                "relpath": rel,
                "path": str(path),
                "reasons": sorted(reasons),
                "exists": lexists(path),
                "is_dir": path.is_dir() and not path.is_symlink(),
                "logical_size": logical,
                "physical_size": physical,
                "protected_descendants": protected[:50],
                "protected_descendant_count": len(protected),
            }
        )

    return {
        "format": 1,
        "project_name": config.project_name,
        "generated_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
        "workspace_root": str(root),
        "provider": config.provider,
        "provider_root": str(provider_root),
        "quarantine_dirname": QUARANTINE_DIRNAME,
        "entries": entries,
    }


def write_plan(plan: dict[str, Any], plan_out: str, logger: Logger) -> Path:
    path = Path(plan_out).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    logger.log(f"Wrote cleanup plan: {path}")
    return path


def print_plan_summary(plan: dict[str, Any], logger: Logger) -> None:
    entries = plan["entries"]
    logical = sum(entry["logical_size"] for entry in entries)
    physical = sum(entry["physical_size"] for entry in entries)
    protected = sum(entry["protected_descendant_count"] for entry in entries)
    logger.log(
        f"Cleanup candidate(s): {len(entries)} "
        f"(logical {logical / 1024 / 1024:.1f} MiB, local {physical / 1024 / 1024:.1f} MiB, "
        f"protected descendant(s): {protected})"
    )
    for entry in entries:
        logger.log(
            f"  - {entry['relpath']} "
            f"({', '.join(entry['reasons'])}; protected={entry['protected_descendant_count']})"
        )


def quarantine_from_plan(plan: dict[str, Any], provider_root: Path, quarantine_dir: Path, logger: Logger) -> None:
    provider_root = provider_root.resolve()
    quarantine_dir = quarantine_dir.resolve()
    try:
        quarantine_dir.relative_to(provider_root)
    except ValueError as exc:
        raise DevSyncError(f"Quarantine directory must be under provider root: {quarantine_dir}") from exc

    if str(provider_root) != str(Path(plan.get("provider_root", "")).resolve()):
        raise DevSyncError("Plan provider_root does not match current config. Refusing to apply stale/wrong plan.")

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    quarantine_base = quarantine_dir / stamp
    moved = 0
    failures: list[str] = []

    for entry in plan.get("entries", []):
        rel_target = safe_relpath(entry["relpath"])
        source = resolve_under_leaf(provider_root, rel_target)
        if not lexists(source):
            continue
        dest = resolve_under_leaf(quarantine_base, rel_target)
        dest.parent.mkdir(parents=True, exist_ok=True)
        logger.log(f"quarantine: {source} -> {dest}")
        if lexists(dest):
            raise DevSyncError(f"Quarantine destination already exists: {dest}")
        try:
            shutil.move(str(source), str(dest))
            moved += 1
        except OSError as exc:
            failures.append(f"{source}: {exc}")
            logger.log(f"  failed: {exc}")

    logger.log(f"Quarantined {moved} item(s) into {quarantine_base}")
    logger.log("Run dev-sync-verify-full.sh, then purge quarantine only after review.")
    if failures:
        raise DevSyncError("Some quarantine moves failed:\n  - " + "\n  - ".join(failures))


def main() -> int:
    args = build_parser().parse_args()
    root = Path(__file__).resolve().parent.parent
    options = RunOptions(dry_run=args.apply_plan is None, verbose=args.verbose)
    logger = Logger(root, "prune-excluded", options)

    try:
        config = load_config(root)
        provider = require_local_provider(config)
        provider_root = provider.get_project_folder()
        if not provider_root.is_dir():
            raise DevSyncError(f"Provider project folder does not exist: {provider_root}")

        if args.apply:
            raise DevSyncError("Direct --apply is disabled. Use --plan-out, inspect it, then --apply-plan.")

        if args.apply_plan:
            plan_path = Path(args.apply_plan).expanduser()
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            quarantine_dir = Path(args.quarantine_dir).expanduser()
            if not quarantine_dir.is_absolute():
                quarantine_dir = provider_root / quarantine_dir
            quarantine_from_plan(plan, provider_root, quarantine_dir, logger)
            return 0

        plan = build_plan(root, config, provider_root, logger)
        print_plan_summary(plan, logger)
        if args.plan_out:
            write_plan(plan, args.plan_out, logger)
        else:
            logger.log("Dry-run only. Re-run with --plan-out <file>, inspect it, then --apply-plan <file>.")
        return 0
    except ConfigReviewRequired as exc:
        logger.log(str(exc))
        return 2
    except DevSyncError as exc:
        logger.log(str(exc))
        return 1
    finally:
        logger.close()


if __name__ == "__main__":
    sys.exit(main())
