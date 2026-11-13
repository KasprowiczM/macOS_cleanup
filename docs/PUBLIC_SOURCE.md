# Public-source maintenance

The source history was sanitized on 2026-11-13 to exclude private development captures, generated machine maps, local agent settings and obsolete screenshots. Public authorship and the project license remain. Branch and release-tag names were retained; rewritten commit identifiers differ from earlier private clones.

Use a fresh clone in a separate directory when migrating from an older private checkout. The current main installer refuses to continue when a local release tag points to a different commit than the fetched official tag; it preserves local refs and files. Set MACOS_CLEANUP_DIR to an unused directory for a fresh installation. Do not merge an old clone’s unsanitized branches into the public history.

## Release integrity

The cleanup implementation, policy rules and language resources were preserved. Verification tools were adjusted because private baseline captures are no longer distributed. Each affected checksum manifest was updated. The original v3.0.0 predates checksum manifests; use the current supported release for installation.

G14 prints an explicit skip when `baseline/pre` or `baseline/post` is absent; a skip is not a pass. To perform a local baseline comparison, capture the two versions with `tools/baseline_capture.sh` into those ignored directories, then run `tools/verify_release.sh --gate G14`. Generated output may contain machine paths and must be reviewed before sharing. Existing development branches may retain pre-existing stale manifests; release installation is supported from verified release tags, not arbitrary development tips.

## Privacy boundary

Machine reports, baseline outputs, graph caches, local agent overlays and environment files stay outside tracked source. The ignore rules reduce accidental additions; they do not redact content or prevent a forced add. Review staged files and scan all refs before future publication.

Git history rewriting cannot itself prove that a hosting provider has purged cached old objects. Verify provider-side cleanup before changing a formerly private repository’s visibility.
