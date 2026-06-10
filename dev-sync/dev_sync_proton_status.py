from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from dev_sync_core import (
    ConfigReviewRequired,
    DevSyncError,
    MANIFEST_FILENAME,
    Logger,
    RunOptions,
    load_config,
    require_local_provider,
    scan_overlay_files,
)


BOOL_FIELDS = [
    "isUploaded",
    "isUploading",
    "isDownloaded",
    "isDownloading",
    "isSyncPaused",
    "hasUnresolvedConflicts",
]


@dataclass(frozen=True)
class FileProviderStatus:
    path: Path
    exists: bool
    fields: dict[str, int | None]
    upload_error: str
    remove_download_available: bool
    command_failed: bool


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check Proton Drive File Provider metadata for the current dev-sync overlay."
    )
    parser.add_argument("--full", action="store_true", help="Check every manifest-listed path.")
    parser.add_argument("--sample", type=int, default=40, help="Number of manifest paths to sample without --full.")
    parser.add_argument("--limit", type=int, default=40, help="Maximum not-ready paths to print.")
    parser.add_argument("--verbose", action="store_true", help="Print every checked path.")
    return parser


def manifest_files(base: Path) -> set[str]:
    path = base / MANIFEST_FILENAME
    if not path.is_file():
        return set()
    payload = json.loads(path.read_text(encoding="utf-8"))
    files = payload.get("files")
    if not isinstance(files, list):
        raise DevSyncError(f"Invalid manifest file list: {path}")
    return {rel for rel in files if isinstance(rel, str) and rel}


def expected_paths(provider_root: Path, config) -> list[Path]:
    paths: list[Path] = [provider_root, provider_root / MANIFEST_FILENAME]
    manifest = manifest_files(provider_root)
    if manifest:
        paths.extend(provider_root / rel for rel in sorted(manifest))
    else:
        paths.extend(provider_root / rel for rel in sorted(scan_overlay_files(provider_root, config)))

    seen: set[str] = set()
    deduped: list[Path] = []
    for path in paths:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(path)
    return deduped


def parse_fileprovider_output(path: Path, output: str, returncode: int) -> FileProviderStatus:
    fields: dict[str, int | None] = {}
    for field in BOOL_FIELDS:
        match = re.search(rf"\b{re.escape(field)} = ([01]);", output)
        fields[field] = int(match.group(1)) if match else None

    error_match = re.search(r'uploadingError = "([^"]+)"', output)
    remove_match = re.search(r"action\.remove_download:.* - YES", output)
    return FileProviderStatus(
        path=path,
        exists=path.exists(),
        fields=fields,
        upload_error=error_match.group(1) if error_match else "",
        remove_download_available=bool(remove_match),
        command_failed=returncode != 0,
    )


def evaluate_path(path: Path) -> FileProviderStatus:
    result = subprocess.run(
        ["fileproviderctl", "evaluate", str(path)],
        check=False,
        text=True,
        capture_output=True,
    )
    return parse_fileprovider_output(path, result.stdout + result.stderr, result.returncode)


def status_ready(status: FileProviderStatus) -> bool:
    return (
        not status.command_failed
        and status.exists
        and status.fields.get("isUploaded") == 1
        and status.fields.get("isUploading") == 0
        and status.fields.get("isSyncPaused") == 0
        and status.fields.get("hasUnresolvedConflicts") == 0
        and not status.upload_error
    )


def main() -> int:
    args = build_parser().parse_args()
    root = Path(__file__).resolve().parent.parent
    options = RunOptions(dry_run=True, verbose=args.verbose)
    logger = Logger(root, "proton-status", options)

    try:
        config = load_config(root)
        provider = require_local_provider(config)
        provider_root = provider.get_project_folder()
        if not provider_root.is_dir():
            raise DevSyncError(f"Provider project folder does not exist: {provider_root}")
        if config.provider != "protondrive" and "proton" not in str(provider_root).lower():
            raise DevSyncError("proton-status is only meaningful for Proton Drive provider roots.")

        paths = expected_paths(provider_root, config)
        checked_paths = paths if args.full else paths[: max(args.sample, 0)]

        logger.log(f"Proton project root: {provider_root}")
        logger.log(f"Checking {len(checked_paths)} of {len(paths)} manifest/root path(s).")
        if not args.full:
            logger.log("Use --full before freeing local disk.")

        statuses: list[FileProviderStatus] = []
        for path in checked_paths:
            status = evaluate_path(path)
            statuses.append(status)
            if args.verbose:
                fields = ", ".join(f"{key}={value}" for key, value in status.fields.items())
                logger.log(f"{path}: {fields}", always_stdout=False)

        not_ready = [status for status in statuses if not status_ready(status)]
        remove_ready = sum(1 for status in statuses if status.remove_download_available)

        logger.log(f"ready: {len(statuses) - len(not_ready)}")
        logger.log(f"not_ready: {len(not_ready)}")
        logger.log(f"remove_download_available: {remove_ready}")

        for status in not_ready[: args.limit]:
            fields = ", ".join(f"{key}={value}" for key, value in status.fields.items())
            reason = status.upload_error or ("command failed" if status.command_failed else "metadata not ready")
            logger.log(f"  - {status.path}: {fields}; {reason}")

        if not_ready:
            logger.log("NOT SAFE TO OFFLOAD: wait for Proton Drive to finish uploading, then rerun this check.")
            return 1

        if not args.full:
            logger.log("Sample passed, but this is not a full upload guarantee.")
            return 0

        logger.log("SAFE TO OFFLOAD WITH PROTON/FINDER UI: all checked overlay paths are uploaded and not uploading.")
        logger.log("Use Proton Drive/Finder 'Remove Download'; do not rm files inside CloudStorage.")
        return 0
    except FileNotFoundError:
        logger.log("fileproviderctl is not available on this system.")
        return 1
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
