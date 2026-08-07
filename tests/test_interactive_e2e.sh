#!/usr/bin/env bash
# =============================================================================
# tests/test_interactive_e2e.sh — End-to-End Interactive Mode & Category Tests
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT_PATH="${PROJ_DIR}/cleanup_all.sh"

# Source test helpers
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

# Note on Category Verifiability:
# 1. trash         -> VERIFIABLE (fixtures in ~/.Trash)
# 2. user-caches   -> VERIFIABLE (fixtures in ~/Library/Caches)
# 3. logs          -> VERIFIABLE (fixtures in ~/Library/Logs)
# 4. system        -> UNVERIFIABLE: System Caches (/Library/Caches) report-only; /tmp system root
# 5. dev           -> VERIFIABLE (fixtures in ~/Library/Developer/Xcode/DerivedData)
# 6. app-leftovers -> VERIFIABLE (fixtures in ~/Library/Application Support)
# 7. time-machine  -> UNVERIFIABLE: tmutil APFS local snapshots require real APFS disk & root
# 8. large-files   -> VERIFIABLE (fixtures in ~/Downloads/*.dmg)

begin_test "Interactive Mode E2E — Answering 'no' preserves all files across all categories"
SANDBOX=$(make_sandbox)
setup_artifact_isolation "$SANDBOX"

FAKE_HOME="${SANDBOX}/home"
mkdir -p "${FAKE_HOME}/.Trash"
mkdir -p "${FAKE_HOME}/Library/Caches/test_user_cache"
mkdir -p "${FAKE_HOME}/Library/Logs/test_log"
mkdir -p "${FAKE_HOME}/Library/Developer/Xcode/DerivedData/TestApp-abc"
mkdir -p "${FAKE_HOME}/Library/Application Support/UninstalledApp"
mkdir -p "${FAKE_HOME}/Downloads"

printf "trash item" > "${FAKE_HOME}/.Trash/trash_item.txt"
printf "cache item" > "${FAKE_HOME}/Library/Caches/test_user_cache/cache.bin"
printf "log item"   > "${FAKE_HOME}/Library/Logs/test_log/app.log"
touch -t 202001010000 "${FAKE_HOME}/Library/Logs/test_log/app.log"
printf "derived data" > "${FAKE_HOME}/Library/Developer/Xcode/DerivedData/TestApp-abc/Build.bin"
printf "leftover item" > "${FAKE_HOME}/Library/Application Support/UninstalledApp/data.db"
dd if=/dev/zero of="${FAKE_HOME}/Downloads/old_installer.dmg" bs=1m count=11 2>/dev/null
touch -t 202001010000 "${FAKE_HOME}/Downloads/old_installer.dmg"

# Shim setup
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

BEFORE_SNAPSHOT="${SANDBOX}/before_snapshot.txt"
(cd "$FAKE_HOME" && find . | sort) > "$BEFORE_SNAPSHOT"

# Feed "n" to all category prompts
INPUT_NO=$(printf "n\nn\nn\nn\nn\nn\nn\nn\nn\nn\n")
env HOME="$FAKE_HOME" PATH="${SHIM_DIR}:${PATH}" \
    LOGS_DIR="${SANDBOX}/logs" REPORTS_DIR="${SANDBOX}/reports" \
    CLEANUP_JOURNAL_FILE="${SANDBOX}/reports/journal.jsonl" \
    QUARANTINE_ROOT="${SANDBOX}/quarantine" \
    bash "$SCRIPT_PATH" --interactive --no-color <<< "$INPUT_NO" > "${SANDBOX}/out_no.log" 2>&1 || true

AFTER_SNAPSHOT="${SANDBOX}/after_snapshot.txt"
(cd "$FAKE_HOME" && find . | sort) > "$AFTER_SNAPSHOT"

assert_eq "$(cat "$BEFORE_SNAPSHOT")" "$(cat "$AFTER_SNAPSHOT")" "Answering 'no' must leave every file intact"
assert_eq "$(cat "$SUDO_RECORDER")" "" "Sudo recorder file MUST be empty"


begin_test "Interactive Mode E2E — Answering 'yes' quarantines precise file list and --restore recovers them"
SANDBOX2=$(make_sandbox)
setup_artifact_isolation "$SANDBOX2"

FAKE_HOME2="${SANDBOX2}/home"
mkdir -p "${FAKE_HOME2}/.Trash"
mkdir -p "${FAKE_HOME2}/Library/Caches/test_user_cache"
mkdir -p "${FAKE_HOME2}/Library/Logs/test_log"
mkdir -p "${FAKE_HOME2}/Library/Developer/Xcode/DerivedData/TestApp-abc"
mkdir -p "${FAKE_HOME2}/Downloads"

printf "trash item" > "${FAKE_HOME2}/.Trash/trash_item.txt"
printf "cache item" > "${FAKE_HOME2}/Library/Caches/test_user_cache/cache.bin"
printf "log item"   > "${FAKE_HOME2}/Library/Logs/test_log/app.log"
touch -t 202001010000 "${FAKE_HOME2}/Library/Logs/test_log/app.log"
printf "derived data" > "${FAKE_HOME2}/Library/Developer/Xcode/DerivedData/TestApp-abc/Build.bin"
dd if=/dev/zero of="${FAKE_HOME2}/Downloads/old_installer.dmg" bs=1m count=11 2>/dev/null
touch -t 202001010000 "${FAKE_HOME2}/Downloads/old_installer.dmg"

SUDO_RECORDER2="${SANDBOX2}/sudo_calls.log"
touch "$SUDO_RECORDER2"

INITIAL_SNAPSHOT="${SANDBOX2}/snapshot_initial.txt"
(cd "$FAKE_HOME2" && find . | sort) > "$INITIAL_SNAPSHOT"

# Feed "y" to all category prompts
INPUT_YES=$(printf "y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n")
env HOME="$FAKE_HOME2" PATH="${SHIM_DIR}:${PATH}" \
    LOGS_DIR="${SANDBOX2}/logs" REPORTS_DIR="${SANDBOX2}/reports" \
    CLEANUP_JOURNAL_FILE="${SANDBOX2}/reports/journal.jsonl" \
    QUARANTINE_ROOT="${SANDBOX2}/quarantine" \
    bash "$SCRIPT_PATH" --interactive --no-color <<< "$INPUT_YES" > "${SANDBOX2}/out_yes.log" 2>&1 || true

# Assert precise file list quarantined (removed from fixture home)
assert_file_absent "${FAKE_HOME2}/.Trash/trash_item.txt" "Trash item MUST be quarantined"
assert_file_absent "${FAKE_HOME2}/Library/Caches/test_user_cache/cache.bin" "User cache item MUST be quarantined"
assert_file_absent "${FAKE_HOME2}/Library/Logs/test_log/app.log" "Log item MUST be quarantined"
assert_file_absent "${FAKE_HOME2}/Library/Developer/Xcode/DerivedData/TestApp-abc/Build.bin" "DerivedData MUST be quarantined"
assert_file_absent "${FAKE_HOME2}/Downloads/old_installer.dmg" "Installer DMG MUST be quarantined"

assert_eq "$(cat "$SUDO_RECORDER2")" "" "Sudo recorder file MUST be empty during 'yes' cleanup"

# Run restore
env HOME="$FAKE_HOME2" PATH="${SHIM_DIR}:${PATH}" \
    LOGS_DIR="${SANDBOX2}/logs" REPORTS_DIR="${SANDBOX2}/reports" \
    CLEANUP_JOURNAL_FILE="${SANDBOX2}/reports/journal.jsonl" \
    QUARANTINE_ROOT="${SANDBOX2}/quarantine" \
    bash "$SCRIPT_PATH" --restore latest --non-interactive --yes > "${SANDBOX2}/out_restore.log" 2>&1 || true

RESTORED_SNAPSHOT="${SANDBOX2}/snapshot_restored.txt"
(cd "$FAKE_HOME2" && find . | sort) > "$RESTORED_SNAPSHOT"

assert_eq "$(cat "$INITIAL_SNAPSHOT")" "$(cat "$RESTORED_SNAPSHOT")" "Restore must return fixture home to original state"


begin_test "Failure Modes — Resilience against filesystem anomalies"
SANDBOX3=$(make_sandbox)
setup_artifact_isolation "$SANDBOX3"
FAKE_HOME3="${SANDBOX3}/home"

mkdir -p "${FAKE_HOME3}/Library/Caches/perm_test"
mkdir -p "${FAKE_HOME3}/Library/Caches/readonly_test"
mkdir -p "${FAKE_HOME3}/Library/Caches/special_chars"

touch "${FAKE_HOME3}/Library/Caches/perm_test/zero.bin"
printf "readonly" > "${FAKE_HOME3}/Library/Caches/readonly_test/read.txt"
chmod 400 "${FAKE_HOME3}/Library/Caches/readonly_test/read.txt"
printf "special" > "${FAKE_HOME3}/Library/Caches/special_chars/file 'with' quote.bin"

env HOME="$FAKE_HOME3" PATH="${SHIM_DIR}:${PATH}" \
    LOGS_DIR="${SANDBOX3}/logs" REPORTS_DIR="${SANDBOX3}/reports" \
    CLEANUP_JOURNAL_FILE="${SANDBOX3}/reports/journal.jsonl" \
    QUARANTINE_ROOT="${SANDBOX3}/quarantine" \
    bash "$SCRIPT_PATH" --auto-safe --non-interactive --yes --no-color > "${SANDBOX3}/out_fail.log" 2>&1 || true

assert_file_exists "${SANDBOX3}/reports/journal.jsonl" "Journal log must be created despite filesystem anomalies"

chmod 700 "${FAKE_HOME3}/Library/Caches/readonly_test/read.txt" 2>/dev/null || true
rm -rf "$SANDBOX" "$SANDBOX2" "$SANDBOX3" 2>/dev/null || true

print_test_summary
