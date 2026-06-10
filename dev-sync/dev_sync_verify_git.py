from __future__ import annotations

import argparse
import sys

from dev_sync_core import repo_root_from_script, verify_git_state


def build_parser() -> argparse.ArgumentParser:
    return argparse.ArgumentParser(description="Verify tracked git state is clean and fully pushed.")


def main() -> int:
    build_parser().parse_args()
    repo_root = repo_root_from_script(__file__)
    result = verify_git_state(repo_root)

    if result.passed:
        print("PASS")
        print(f"Branch: {result.branch}")
        print(f"Upstream: {result.upstream}")
        print("Tracked files are clean and the branch is fully pushed.")
        return 0

    print("FAIL")
    print(f"Branch: {result.branch}")
    print(f"Upstream: {result.upstream or '<missing>'}")
    for failure in result.failures:
        print(f"- {failure}")
    if result.tracked_issues:
        print("Tracked changes:")
        for entry in result.tracked_issues:
            print(f"  {entry}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
