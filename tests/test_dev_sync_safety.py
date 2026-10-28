from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[1]
DEV_SYNC_DIR = REPO_ROOT / "dev-sync"
sys.path.insert(0, str(DEV_SYNC_DIR))

from dev_sync_core import (  # noqa: E402
    DEFAULT_EXCLUDE_PATTERNS,
    DEFAULT_INCLUDE_ALWAYS,
    HARD_EXCLUDE_PATTERNS,
    DevSyncConfig,
    DevSyncError,
    RCloneProvider,
    RunOptions,
    approved_overlay_relpaths,
    copy_relpaths,
    import_overlay,
    read_manifest,
    safe_relpath,
    should_include_candidate,
    verify_full_state,
    write_json,
)
from dev_sync_prune_excluded import quarantine_from_plan  # noqa: E402


def _git_identity_env() -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "GIT_AUTHOR_NAME": "DevSync Test",
            "GIT_AUTHOR_EMAIL": "devsync@example.test",
            "GIT_COMMITTER_NAME": "DevSync Test",
            "GIT_COMMITTER_EMAIL": "devsync@example.test",
        }
    )
    return env


def _run_git(repo: Path, *args: str) -> None:
    command = ["git", *args]
    if args and args[0] == "commit":
        command = [
            "git",
            "-c",
            "user.name=DevSync Test",
            "-c",
            "user.email=devsync@example.test",
            "-c",
            "commit.gpgsign=false",
            *args,
        ]
    subprocess.run(command, cwd=str(repo), check=True, capture_output=True, env=_git_identity_env())


def _init_git_repo(repo: Path, committed: dict[str, str] | None = None) -> None:
    repo.mkdir(parents=True, exist_ok=True)
    _run_git(repo, "init")
    files = committed if committed is not None else {"README.md": "test\n"}
    for relpath, content in files.items():
        path = repo / relpath
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        _run_git(repo, "add", "--", relpath)
    _run_git(repo, "commit", "-m", "init")


def _write_manifest(folder: Path, files: list[str]) -> None:
    (folder / ".dev_sync_manifest.json").write_text(
        json.dumps({"format": 1, "files": files}),
        encoding="utf-8",
    )


def _local_config(project_name: str, provider_path: Path) -> DevSyncConfig:
    return DevSyncConfig(
        project_name=project_name,
        provider="local",
        provider_path=str(provider_path),
    )


class NullLogger:
    def log(self, message: str, always_stdout: bool = True) -> None:
        pass

    def verbose(self, message: str) -> None:
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


class DevSyncCopySafetyTests(unittest.TestCase):
    def test_copy_relpaths_missing_source_leaves_destination_bytes_identical(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source_base = Path(tmp) / "source"
            dest_base = Path(tmp) / "dest"
            source_base.mkdir()
            dest_base.mkdir()
            relpath = "keep.txt"
            original = b"DEST-ORIGINAL-BYTES"
            (dest_base / relpath).write_bytes(original)
            options = RunOptions(dry_run=False, verbose=False)

            with self.assertRaises(DevSyncError):
                copy_relpaths(source_base, dest_base, [relpath], NullLogger(), options)

            dest = dest_base / relpath
            self.assertTrue(dest.is_file())
            self.assertEqual(dest.read_bytes(), original)

    def test_copy_relpaths_read_error_leaves_destination(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source_base = Path(tmp) / "source"
            dest_base = Path(tmp) / "dest"
            source_base.mkdir()
            dest_base.mkdir()
            relpath = "keep.txt"
            original = b"DEST-ORIGINAL-BYTES"
            source = source_base / relpath
            dest = dest_base / relpath
            source.write_bytes(b"SOURCE-SHOULD-NOT-APPLY")
            dest.write_bytes(original)
            os.chmod(source, 0o000)
            try:
                if os.access(source, os.R_OK):
                    self.skipTest("chmod 000 is ineffective on this platform")
                try:
                    with open(source, "rb") as handle:
                        handle.read(1)
                    self.skipTest("chmod 000 is ineffective on this platform")
                except OSError:
                    pass

                options = RunOptions(dry_run=False, verbose=False)
                try:
                    copy_relpaths(source_base, dest_base, [relpath], NullLogger(), options)
                except (OSError, DevSyncError):
                    pass
                else:
                    if dest.is_file() and dest.read_bytes() == b"SOURCE-SHOULD-NOT-APPLY":
                        self.skipTest("chmod 000 is ineffective on this platform")

                self.assertTrue(dest.is_file())
                self.assertEqual(dest.read_bytes(), original)
            finally:
                os.chmod(source, 0o644)


class DevSyncImportProtectionTests(unittest.TestCase):
    def test_import_rejects_directory_that_contains_tracked_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            cloud = Path(tmp) / "cloud"
            project_name = "sample"
            provider_root = cloud / project_name
            tracked_content = "GIT-TRACKED-BYTES\n"
            _init_git_repo(repo, {"src/tracked.txt": tracked_content})

            provider_root.mkdir(parents=True)
            overlay_tracked = provider_root / "src" / "tracked.txt"
            overlay_tracked.parent.mkdir(parents=True)
            overlay_tracked.write_text("OVERLAY-MUST-NOT-REPLACE-TRACKED\n", encoding="utf-8")
            (provider_root / ".env.local").write_text("IMPORTED=1\n", encoding="utf-8")
            _write_manifest(provider_root, ["src", ".env.local"])

            result = import_overlay(repo, _local_config(project_name, cloud), dry_run=False)
            self.assertEqual((repo / "src" / "tracked.txt").read_text(encoding="utf-8"), tracked_content)
            self.assertNotIn("src", result.imported_files)
            self.assertNotIn("src/tracked.txt", result.imported_files)
            self.assertEqual((repo / ".env.local").read_text(encoding="utf-8"), "IMPORTED=1\n")


class DevSyncRcloneSafetyTests(unittest.TestCase):
    def test_rclone_sync_from_uses_files_from_not_whole_repo(self) -> None:
        captured: list[dict[str, object]] = []

        def fake_run(command, **kwargs):
            captured.append({"argv": list(command), "input_text": kwargs.get("input_text")})

            class Result:
                returncode = 0
                stdout = ""
                stderr = ""

            return Result()

        config = DevSyncConfig(
            project_name="sample",
            provider="rclone",
            rclone_remote="dummy",
            rclone_remote_path="backup",
        )
        provider = RCloneProvider(config)

        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp)
            with patch("dev_sync_core.run_command", side_effect=fake_run):
                empty_files, empty_transport = provider.sync_from(dest, dry_run=False, files=[])
                self.assertEqual(empty_transport, "rclone")
                self.assertEqual(empty_files, [])
                copy_calls = [
                    item
                    for item in captured
                    if isinstance(item["argv"], list)
                    and item["argv"]
                    and item["argv"][0] == "rclone"
                    and "copy" in item["argv"]
                ]
                self.assertEqual(copy_calls, [])

                captured.clear()
                copied, transport = provider.sync_from(dest, dry_run=False, files=["private.env"])
                self.assertEqual(transport, "rclone")
                self.assertEqual(copied, ["private.env"])
                copy_calls = [
                    item
                    for item in captured
                    if isinstance(item["argv"], list)
                    and item["argv"]
                    and item["argv"][0] == "rclone"
                    and "copy" in item["argv"]
                ]
                self.assertEqual(len(copy_calls), 1)
                argv = copy_calls[0]["argv"]
                joined = " ".join(str(part) for part in argv)
                self.assertIn("--files-from", joined)
                payload = copy_calls[0]["input_text"]
                if payload is None:
                    files_from_value = ""
                    for index, part in enumerate(argv):
                        if part == "--files-from" and index + 1 < len(argv):
                            files_from_value = str(argv[index + 1])
                            break
                        if str(part).startswith("--files-from="):
                            files_from_value = str(part).split("=", 1)[1]
                            break
                    if files_from_value and files_from_value != "-":
                        payload = Path(files_from_value).read_text(encoding="utf-8")
                    else:
                        payload = ""
                self.assertIn("private.env", str(payload))


class DevSyncRcloneImportFilterTests(unittest.TestCase):
    """P1-3: a forged rclone remote must not bypass the hard-exclude list."""

    REMOTE_FILES = [
        ".env.local",
        ".git/config",
        ".git/hooks/pre-commit",
        ".GIT/hooks/post-checkout",
        ".ssh/id_rsa",
        "secrets/prod.txt",
        "SECRETS/prod.txt",
        "server.pem",
        "server.PEM",
        "node_modules/pkg/index.js",
        "readme.MD",
    ]

    def _rclone_import(self, repo: Path) -> object:
        config = DevSyncConfig(
            project_name="sample",
            provider="rclone",
            rclone_remote="dummy",
            rclone_remote_path="backup",
        )
        with patch.object(RCloneProvider, "validate", return_value=[]), patch.object(
            RCloneProvider, "is_available", return_value=True
        ), patch.object(RCloneProvider, "list_remote_files", return_value=list(self.REMOTE_FILES)):
            return import_overlay(repo, config, dry_run=True)

    def test_rclone_import_applies_hard_excludes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            _init_git_repo(repo, {"README.md": "tracked\n"})
            result = self._rclone_import(repo)
            self.assertEqual(result.imported_files, [".env.local"])

    def test_case_variant_of_tracked_file_is_not_imported(self) -> None:
        self.assertEqual(approved_overlay_relpaths(["readme.MD", "SRC/x.txt"], ["README.md", "src/x.txt"]), [])
        self.assertEqual(approved_overlay_relpaths(["Src"], ["src/x.txt"]), [])

    def test_unicode_normalization_variant_of_tracked_file_is_not_imported(self) -> None:
        import unicodedata

        nfc = unicodedata.normalize("NFC", "Café.txt")
        nfd = unicodedata.normalize("NFD", "Café.txt")
        self.assertEqual(approved_overlay_relpaths([nfd], [nfc]), [])
        self.assertEqual(approved_overlay_relpaths([nfc], [nfd]), [])

    def test_git_leaf_file_is_hard_excluded(self) -> None:
        config = DevSyncConfig(project_name="sample", provider="local", provider_path="/nonexistent")
        for rel in (".git", "sub/.git", "sub/.GIT"):
            self.assertFalse(should_include_candidate(rel, config), rel)

    def test_rclone_sync_from_refuses_symlinked_destination_ancestor(self) -> None:
        config = DevSyncConfig(
            project_name="sample",
            provider="rclone",
            rclone_remote="dummy",
            rclone_remote_path="backup",
        )
        provider = RCloneProvider(config)
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "repo"
            outside = Path(tmp) / "outside"
            dest.mkdir()
            outside.mkdir()
            (dest / "link").symlink_to(outside)
            with patch("dev_sync_core.run_command") as fake_run:
                with self.assertRaises(DevSyncError):
                    provider.sync_from(dest, dry_run=False, files=["link/x.env"])
                fake_run.assert_not_called()

    def _rclone_provider(self) -> RCloneProvider:
        return RCloneProvider(
            DevSyncConfig(
                project_name="sample",
                provider="rclone",
                rclone_remote="dummy",
                rclone_remote_path="backup",
            )
        )

    def test_rclone_sync_from_passes_names_raw(self) -> None:
        # `--files-from` strips whitespace, so " README.md" would copy the
        # tracked README.md; `--files-from-raw` keeps the approved name.
        with tempfile.TemporaryDirectory() as tmp:
            with patch("dev_sync_core.run_command") as fake_run:
                self._rclone_provider().sync_from(Path(tmp), dry_run=False, files=["private.env"])
            argv = fake_run.call_args.args[0]
            self.assertIn("--files-from-raw", argv)
            self.assertNotIn("--files-from", argv)

    def test_rclone_sync_from_rejects_whitespace_or_control_names(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for rel in (" README.md", "README.md ", "a/ b.env", "x\t.env", "#hash.env"):
                with patch("dev_sync_core.run_command") as fake_run:
                    if rel.startswith("#"):
                        self._rclone_provider().sync_from(Path(tmp), dry_run=False, files=[rel])
                        self.assertIn("--files-from-raw", fake_run.call_args.args[0])
                        continue
                    with self.assertRaises(DevSyncError, msg=repr(rel)):
                        self._rclone_provider().sync_from(Path(tmp), dry_run=False, files=[rel])
                    fake_run.assert_not_called()

    def test_hard_excludes_ignore_case(self) -> None:
        config = DevSyncConfig(project_name="sample", provider="local", provider_path="/nonexistent")
        for rel in (".GIT/hooks/pre-commit", "SECRETS/a.txt", ".SSH/id_rsa", "id.PEM", "cert.Key"):
            self.assertFalse(should_include_candidate(rel, config), rel)


class DevSyncVerifyFullTests(unittest.TestCase):
    def test_verify_full_fails_when_provider_file_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            cloud = Path(tmp) / "cloud"
            project_name = "sample"
            provider_root = cloud / project_name
            _init_git_repo(repo)
            (repo / ".env.local").write_text("LOCAL=1\n", encoding="utf-8")
            provider_root.mkdir(parents=True)
            _write_manifest(provider_root, [".env.local"])

            result = verify_full_state(repo, _local_config(project_name, cloud))
            self.assertFalse(result.passed)
            self.assertIn(".env.local", result.missing_from_provider)

    def test_verify_full_fails_when_local_file_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            cloud = Path(tmp) / "cloud"
            project_name = "sample"
            provider_root = cloud / project_name
            _init_git_repo(repo)
            provider_root.mkdir(parents=True)
            (provider_root / ".env.local").write_text("PROVIDER=1\n", encoding="utf-8")
            _write_manifest(provider_root, [".env.local"])

            result = verify_full_state(repo, _local_config(project_name, cloud))
            self.assertFalse(result.passed)
            self.assertIn(".env.local", result.missing_from_local)


class DevSyncSymlinkLeafTests(unittest.TestCase):
    def test_prune_moves_symlink_leaf_not_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            provider_root = Path(tmp) / "provider"
            provider_root.mkdir()
            private = provider_root / "private.txt"
            private.write_text("KEEP-ME\n", encoding="utf-8")
            stale_link = provider_root / "stale-link"
            os.symlink("private.txt", stale_link)
            quarantine_dir = provider_root / "dev_sync_quarantine"
            plan = {
                "provider_root": str(provider_root.resolve()),
                "entries": [{"relpath": "stale-link"}],
            }

            quarantine_from_plan(plan, provider_root, quarantine_dir, NullLogger())

            self.assertTrue(private.is_file())
            self.assertEqual(private.read_text(encoding="utf-8"), "KEEP-ME\n")
            self.assertFalse(os.path.lexists(stale_link))
            moved = list(quarantine_dir.rglob("stale-link"))
            self.assertEqual(len(moved), 1)
            self.assertTrue(moved[0].is_symlink())
            self.assertEqual(os.readlink(moved[0]), "private.txt")

    def test_write_json_refuses_symlink_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            real = root / "outside.json"
            original = b'{"keep": true}\n'
            real.write_bytes(original)
            manifest = root / "overlay" / ".dev_sync_manifest.json"
            manifest.parent.mkdir()
            os.symlink(real, manifest)

            with self.assertRaises(DevSyncError):
                write_json(manifest, {"format": 1, "files": []})

            self.assertEqual(real.read_bytes(), original)
            self.assertTrue(manifest.is_symlink())


if __name__ == "__main__":
    unittest.main()
