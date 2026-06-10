from __future__ import annotations

import argparse
import sys

from dev_sync_core import (
    ConfigReviewRequired,
    DevSyncError,
    import_overlay,
    load_config,
    print_config_hint,
    repo_root_from_script,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Import private files from configured cloud provider into this project.")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be copied without writing files.")
    parser.add_argument("--verbose", action="store_true", help="Print copied file paths and transport details.")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    repo_root = repo_root_from_script(__file__)

    try:
        config = load_config(repo_root)
    except ConfigReviewRequired as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print(print_config_hint(repo_root), file=sys.stderr)
        return 2
    except DevSyncError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print(print_config_hint(repo_root), file=sys.stderr)
        return 1

    try:
        result = import_overlay(repo_root, config, dry_run=args.dry_run, verbose=args.verbose)
    except DevSyncError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    mode = "DRY-RUN" if result.dry_run else "IMPORT"
    print(f"{mode} PASS")
    print(f"Project root: {repo_root}")
    print(f"Provider: {config.provider}")
    print(f"Source: {result.source}")
    print(f"Files selected: {len(result.imported_files)}")
    print(f"Tracked provider files skipped: {len(result.skipped_tracked_files)}")
    print(f"Transport: {result.transport}")
    print(f"Log: {result.log_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
