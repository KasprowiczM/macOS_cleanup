# macOS_cleanup — Privacy & Security Architecture

## Privacy Principles & Guarantees

`macOS_cleanup` is designed with strict local-first privacy guarantees:

1. **Zero External Telemetry & Zero Network Calls**: `macOS_cleanup` never sends system metrics, file paths, logs, or telemetry to external servers. All operations execute strictly locally on your macOS machine.
2. **Local Artifact Storage**: All generated reports (`reports/report_*.md`), plans (`reports/plan_*.json`), and logs (`logs/cleanup_*.log`) remain exclusively in local project directories under explicit user control.
3. **Path Redaction (`--redact`)**: When `--redact` is passed on the command line, personal home directory paths (e.g. `/Users/username/Library/...`) are automatically sanitized to `~/...` in output reports and log streams to protect personal identity when sharing logs.
4. **Explicit Artifact Retention**: Old logs and reports are pruned only when `--prune-artifacts` is requested. Analyze, plan, list and dry-run modes do not delete artifacts; the default retention window is 30 days.
5. **No Inspection of Private User Files**: `macOS_cleanup` NEVER scans or deletes documents (`~/Documents`), desktop files (`~/Desktop`), photos (`~/Pictures`), keychains (`~/Library/Keychains`), mail contents (`~/Library/Mail`), or password manager data.

---

## Verification & Compliance

- **Network Isolation (Gate G15)**: `tools/verify_release.sh` performs static analysis ensuring zero `curl`, `wget`, `nc`, or network calls are present in any cleanup modules.
- **Fail-Closed Protection**: Any path failing pathguard validation or normalizer checks is immediately blocked without modification.
