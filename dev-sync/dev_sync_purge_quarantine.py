from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from dev_sync_core import (
    ConfigReviewRequired,
    DevSyncError,
    QUARANTINE_DIRNAME,
    Logger,
    RunOptions,
    load_config,
    require_local_provider,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Permanently delete cloud overlay quarantine folders.")
    parser.add_argument("--apply", action="store_true", help="Delete the quarantine. Default is dry-run.")
    parser.add_argument("--verbose", action="store_true", help="List quarantined paths.")
    return parser


def tree_size(path: Path) -> tuple[int, int, int]:
    files = 0
    logical = 0
    physical = 0
    if not path.exists():
        return files, logical, physical
    for child in path.rglob("*"):
        try:
            stat = child.lstat()
        except OSError:
            continue
        files += 1 if child.is_file() or child.is_symlink() else 0
        logical += stat.st_size
        physical += getattr(stat, "st_blocks", 0) * 512
    return files, logical, physical


def main() -> int:
    args = build_parser().parse_args()
    root = Path(__file__).resolve().parent.parent
    options = RunOptions(dry_run=not args.apply, verbose=args.verbose)
    logger = Logger(root, "purge-quarantine", options)

    try:
        config = load_config(root)
        provider = require_local_provider(config)
        provider_root = provider.get_project_folder()
        quarantine = provider_root / QUARANTINE_DIRNAME

        if not quarantine.exists():
            logger.log(f"No provider quarantine found: {quarantine}")
            return 0
        if not quarantine.is_dir():
            raise DevSyncError(f"Quarantine path is not a directory: {quarantine}")

        files, logical, physical = tree_size(quarantine)
        logger.log(
            f"Provider quarantine: {quarantine} "
            f"({files} file(s), logical {logical / 1024 / 1024:.1f} MiB, local {physical / 1024 / 1024:.1f} MiB)"
        )
        if args.verbose:
            for path in sorted(quarantine.rglob("*")):
                logger.log(f"  - {path}", always_stdout=False)

        if not args.apply:
            logger.log("Dry-run only. Re-run with --apply to permanently delete this quarantine.")
            return 0

        shutil.rmtree(quarantine)
        logger.log("Quarantine deleted.")
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
