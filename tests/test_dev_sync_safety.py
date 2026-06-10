from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEV_SYNC_DIR = REPO_ROOT / "dev-sync"
sys.path.insert(0, str(DEV_SYNC_DIR))

from dev_sync_core import (  # noqa: E402
    DEFAULT_EXCLUDE_PATTERNS,
    DEFAULT_INCLUDE_ALWAYS,
    HARD_EXCLUDE_PATTERNS,
    DevSyncConfig,
    DevSyncError,
    read_manifest,
    safe_relpath,
    should_include_candidate,
)
from dev_sync_prune_excluded import quarantine_from_plan  # noqa: E402


class NullLogger:
    def log(self, message: str, always_stdout: bool = True) -> None:
        pass


class DevSyncPathSafetyTests(unittest.TestCase):
    def test_safe_relpath_rejects_escape_paths(self) -> None:
        bad_paths = [
            "../outside",
            "nested/../../outside",
            "/tmp/outside",
            "C:/outside",
            "nested/\noutside",
            "",
            ".",
        ]
        for bad_path in bad_paths:
            with self.subTest(path=bad_path):
                with self.assertRaises(DevSyncError):
                    safe_relpath(bad_path)

    def test_safe_relpath_keeps_normal_project_paths(self) -> None:
        self.assertEqual(safe_relpath("./.env.local"), ".env.local")
        self.assertEqual(safe_relpath("dir/private.txt"), "dir/private.txt")

    def test_read_manifest_rejects_unsafe_relpaths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".dev_sync_manifest.json").write_text(
                json.dumps({"format": 1, "files": ["../outside"]}),
                encoding="utf-8",
            )
            with self.assertRaises(DevSyncError):
                read_manifest(root)

    def test_quarantine_plan_rebuilds_source_from_safe_relpath(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "provider"
            base.mkdir()
            plan = {
                "provider_root": str(base),
                "entries": [
                    {
                        "path": str(base / "safe.txt"),
                        "relpath": "../outside.txt",
                    }
                ],
            }
            with self.assertRaises(DevSyncError):
                quarantine_from_plan(plan, base, base / "dev_sync_quarantine", NullLogger())


class DevSyncDefaultPolicyTests(unittest.TestCase):
    def test_cleanup_generated_outputs_are_excluded(self) -> None:
        for pattern in ["logs/", "reports/", "graphify-out/", "dev_sync_logs/"]:
            with self.subTest(pattern=pattern):
                self.assertIn(pattern, DEFAULT_EXCLUDE_PATTERNS)

    def test_update_toolkit_private_files_are_not_included(self) -> None:
        for pattern in ["APPLICATIONS.md", "UPDATES.md", ".mac_update_prefs"]:
            with self.subTest(pattern=pattern):
                self.assertNotIn(pattern, DEFAULT_INCLUDE_ALWAYS)

    def test_key_material_and_local_agent_state_are_hard_excluded(self) -> None:
        for pattern in [
            "secrets/",
            ".ssh/",
            "*.pem",
            "*.key",
            "*.p12",
            "*.pfx",
            "*.crt",
            "*.cer",
            ".claude/settings.local.json",
            ".gemini/settings.local.json",
        ]:
            with self.subTest(pattern=pattern):
                self.assertIn(pattern, HARD_EXCLUDE_PATTERNS)

    def test_candidate_filter_matches_project_policy(self) -> None:
        config = DevSyncConfig(project_name="macOS_cleanup")
        rejected = [
            "logs/cleanup.log",
            "reports/report.md",
            "graphify-out/graph.json",
            "secrets/token.txt",
            ".ssh/id_ed25519",
            ".claude/settings.local.json",
            ".gemini/settings.local.json",
        ]
        accepted = [
            ".dev_sync_config.json",
            ".env.local",
            ".dev.vars.local",
            ".vscode/settings.json",
        ]

        for relpath in rejected:
            with self.subTest(rejected=relpath):
                self.assertFalse(should_include_candidate(relpath, config))
        for relpath in accepted:
            with self.subTest(accepted=relpath):
                self.assertTrue(should_include_candidate(relpath, config))


if __name__ == "__main__":
    unittest.main()
