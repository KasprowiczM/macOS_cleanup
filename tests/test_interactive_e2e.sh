#!/usr/bin/env bash
# =============================================================================
# tests/test_interactive_e2e.sh — End-to-End Interactive Mode & Failure Tests
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT_PATH="${PROJ_DIR}/cleanup_all.sh"

# Source test helpers
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

begin_test "Interactive Mode E2E — Answering 'no' preserves all files"
SANDBOX=$(make_sandbox)
setup_artifact_isolation "$SANDBOX"

# Create fake HOME structure with files in 8 categories
FAKE_HOME="${SANDBOX}/home"
mkdir -p "${FAKE_HOME}/Library/Caches/test_app"
mkdir -p "${FAKE_HOME}/Library/Logs/test_app"
mkdir -p "${FAKE_HOME}/.Trash"
mkdir -p "${FAKE_HOME}/Downloads"
mkdir -p "${FAKE_HOME}/.npm/_cacache"
mkdir -p "${FAKE_HOME}/.cache/test_cache"

printf "cache data" > "${FAKE_HOME}/Library/Caches/test_app/cache.bin"
printf "log data" > "${FAKE_HOME}/Library/Logs/test_app/test.log"
printf "trash data" > "${FAKE_HOME}/.Trash/junk.txt"
printf "installer data" > "${FAKE_HOME}/Downloads/test_installer.dmg"
printf "npm data" > "${FAKE_HOME}/.npm/_cacache/data.bin"

# PATH shim setup for tools recorder
SHIM_DIR="${SANDBOX}/shims"
mkdir -p "$SHIM_DIR"
SUDO_RECORDER="${SANDBOX}/sudo_calls.log"
TOOL_RECORDER="${SANDBOX}/tool_calls.log"
touch "$SUDO_RECORDER" "$TOOL_RECORDER"

for tool in sudo brew docker npm yarn pnpm corepack tmutil xcrun; do
    cat << EOF > "${SHIM_DIR}/${tool}"
#!/usr/bin/env bash
if [[ "${tool}" == "sudo" ]]; then
    echo "sudo \$*" >> "${SUDO_RECORDER}"
else
    echo "${tool} \$*" >> "${TOOL_RECORDER}"
fi
exit 1
EOF
    chmod +x "${SHIM_DIR}/${tool}"
done

# Capture initial file tree snapshot
BEFORE_SNAPSHOT="${SANDBOX}/before_snapshot.txt"
(cd "$FAKE_HOME" && find . | sort) > "$BEFORE_SNAPSHOT"

# Run cleanup in interactive mode, feeding "n" to all prompts
INPUT_NO=$(printf "n\nn\nn\nn\nn\nn\nn\nn\nn\nn\n")
env HOME="$FAKE_HOME" PATH="${SHIM_DIR}:${PATH}" \
    LOGS_DIR="${SANDBOX}/logs" REPORTS_DIR="${SANDBOX}/reports" \
    CLEANUP_JOURNAL_FILE="${SANDBOX}/reports/journal.jsonl" \
    QUARANTINE_ROOT="${SANDBOX}/quarantine" \
    bash "$SCRIPT_PATH" --interactive --no-color <<< "$INPUT_NO" > "${SANDBOX}/out_no.log" 2>&1 || true

AFTER_SNAPSHOT="${SANDBOX}/after_snapshot.txt"
(cd "$FAKE_HOME" && find . | sort) > "$AFTER_SNAPSHOT"

assert_eq "$(cat "$BEFORE_SNAPSHOT")" "$(cat "$AFTER_SNAPSHOT")" "All files must remain intact when user answers 'no'"
assert_eq "$(cat "$SUDO_RECORDER")" "" "No sudo invocations recorded"


begin_test "Interactive Mode E2E — Answering 'y' quarantines expected files and --restore recovers them"
SANDBOX2=$(make_sandbox)
setup_artifact_isolation "$SANDBOX2"

FAKE_HOME2="${SANDBOX2}/home"
mkdir -p "${FAKE_HOME2}/Library/Caches/test_app"
mkdir -p "${FAKE_HOME2}/Library/Logs/test_app"
mkdir -p "${FAKE_HOME2}/.Trash"
mkdir -p "${FAKE_HOME2}/Downloads"

printf "cache data" > "${FAKE_HOME2}/Library/Caches/test_app/cache.bin"
printf "log data" > "${FAKE_HOME2}/Library/Logs/test_app/test.log"
printf "trash data" > "${FAKE_HOME2}/.Trash/junk.txt"

(cd "$FAKE_HOME2" && find . | sort) > "${SANDBOX2}/snapshot_initial.txt"

# Feed "y" to interactive prompts
INPUT_YES=$(printf "y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n")
env HOME="$FAKE_HOME2" PATH="${SHIM_DIR}:${PATH}" \
    LOGS_DIR="${SANDBOX2}/logs" REPORTS_DIR="${SANDBOX2}/reports" \
    CLEANUP_JOURNAL_FILE="${SANDBOX2}/reports/journal.jsonl" \
    QUARANTINE_ROOT="${SANDBOX2}/quarantine" \
    bash "$SCRIPT_PATH" --interactive --no-color <<< "$INPUT_YES" > "${SANDBOX2}/out_yes.log" 2>&1 || true

# Assert files were moved to quarantine
assert_file_absent "${FAKE_HOME2}/Library/Caches/test_app/cache.bin" "Cache file should be quarantined"

# Run restore
env HOME="$FAKE_HOME2" PATH="${SHIM_DIR}:${PATH}" \
    LOGS_DIR="${SANDBOX2}/logs" REPORTS_DIR="${SANDBOX2}/reports" \
    CLEANUP_JOURNAL_FILE="${SANDBOX2}/reports/journal.jsonl" \
    QUARANTINE_ROOT="${SANDBOX2}/quarantine" \
    bash "$SCRIPT_PATH" --restore latest --non-interactive --yes > "${SANDBOX2}/out_restore.log" 2>&1 || true

(cd "$FAKE_HOME2" && find . | sort) > "${SANDBOX2}/snapshot_restored.txt"

assert_eq "$(cat "${SANDBOX2}/snapshot_initial.txt")" "$(cat "${SANDBOX2}/snapshot_restored.txt")" "Restore must return fixture home to original state"


begin_test "Failure Modes — Resilience against filesystem anomalies"
SANDBOX3=$(make_sandbox)
setup_artifact_isolation "$SANDBOX3"
FAKE_HOME3="${SANDBOX3}/home"

mkdir -p "${FAKE_HOME3}/Library/Caches/perm_test"
mkdir -p "${FAKE_HOME3}/Library/Caches/readonly_test"
mkdir -p "${FAKE_HOME3}/Library/Caches/special_chars"

# 1. Zero-byte file
touch "${FAKE_HOME3}/Library/Caches/perm_test/zero.bin"

# 2. Read-only file
printf "readonly" > "${FAKE_HOME3}/Library/Caches/readonly_test/read.txt"
chmod 400 "${FAKE_HOME3}/Library/Caches/readonly_test/read.txt"

# 3. Filename with quotes/spaces
printf "special" > "${FAKE_HOME3}/Library/Caches/special_chars/file 'with' quote.bin"

# Execute dry-run analysis and auto-safe cleanup
env HOME="$FAKE_HOME3" PATH="${SHIM_DIR}:${PATH}" \
    LOGS_DIR="${SANDBOX3}/logs" REPORTS_DIR="${SANDBOX3}/reports" \
    CLEANUP_JOURNAL_FILE="${SANDBOX3}/reports/journal.jsonl" \
    QUARANTINE_ROOT="${SANDBOX3}/quarantine" \
    bash "$SCRIPT_PATH" --auto-safe --non-interactive --yes --no-color > "${SANDBOX3}/out_fail.log" 2>&1 || true

# Run completes with journal events
assert_file_exists "${SANDBOX3}/reports/journal.jsonl" "Journal log must be created despite filesystem anomalies"

# Restore permissions for cleanup
chmod 700 "${FAKE_HOME3}/Library/Caches/readonly_test/read.txt" 2>/dev/null || true
rm -rf "$SANDBOX" "$SANDBOX2" "$SANDBOX3" 2>/dev/null || true

print_test_summary
