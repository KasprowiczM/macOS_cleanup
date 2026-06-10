from __future__ import annotations

import argparse
import sys

from dev_sync_core import (
    ConfigReviewRequired,
    DevSyncError,
    load_config,
    print_config_hint,
    repo_root_from_script,
    verify_full_state,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify local repo equals Git-tracked files plus the cloud provider overlay."
    )
    parser.add_argument("--verbose", action="store_true", help="Print file lists for each report section.")
    return parser


def print_section(label: str, items: list[str]) -> None:
    print(f"{label}:")
    if items:
        for item in items:
            print(f"  {item}")
    else:
        print("  <none>")


def main() -> int:
    args = build_parser().parse_args()
    repo_root = repo_root_from_script(__file__)

    try:
        config = load_config(repo_root)
        result = verify_full_state(repo_root, config, verbose=args.verbose)
    except ConfigReviewRequired as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print(print_config_hint(repo_root), file=sys.stderr)
        return 2
    except DevSyncError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print("PASS" if result.passed else "FAIL")
    print(f"Tracked files (GitHub snapshot): {result.git_snapshot_count}")
    print(f"Provider ({result.provider_name}) files: {result.provider_snapshot_count}")
    print(f"Local files: {result.local_snapshot_count}")
    print(f"Provider root: {result.provider_root}")

    print_section("Dirty tracked files", result.dirty_tracked_entries)
    print_section("Orphan local files", result.orphan_local)
    print_section("Missing-from-local files", result.missing_from_local)
    print_section("Missing-from-provider overlay files", result.missing_from_provider)
    print_section("Stale provider-only files", result.stale_provider_only)
    print_section("Overlay content mismatches", result.content_mismatches)
    print_section("Content-not-checked sensitive paths", result.content_not_checked)

    print(f"Log: {result.log_path}")
    if result.stale_provider_only:
        print("Stale provider-only files do not fail reconstruction, but prune-excluded can quarantine them.")

    return 0 if result.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
