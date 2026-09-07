#!/usr/bin/env bash
# =============================================================================
# tests/test_report_parity.sh
#
# Everything a run measures must be something the run can also show and act on.
# Three separate lists had drifted apart, and each gap was invisible in a green
# suite because every existing test called functions directly:
#
#   * lib/reporter.sh kept its own label list — 21 entries against 37 live
#     ledger keys. Measured on 2026-09-01: the terminal summary printed 13.05 GB
#     across 12 categories, the markdown report itemised 6. app-caches (1.04 GB),
#     cargo, brew, pip, swift-pm and xcode-derived were sized, added to the
#     headline total, and printed nowhere.
#   * Four of the labels it did carry ("logs", "dev", "derived-data",
#     "xcode-device-support") named keys nothing ever sets, so they could never
#     render, while clean_logs and clean_ios_device_support READ those same
#     phantom keys and therefore prompted with "0 B".
#   * clean_xcode_simulators looked for "simulators:__unavailable__" while the
#     analyzer emits "ios_simulators:<path>", so unavailable simulators were
#     sized and reported but never offered for deletion.
#
# These assertions are structural on purpose: they compare what the analyzer
# writes against what the reporter and cleaners read.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_parity.XXXXXX)"
export HOME="$SANDBOX"
export LOG_LEVEL="ERROR"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"
setup_artifact_isolation "$SANDBOX"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/pathguard.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/policy.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/cleaner.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/reporter.sh"

trap 'rm -rf "$SANDBOX"' EXIT

registry_has_key() {
    local needle="$1" row
    for row in "${CATEGORY_REGISTRY[@]}"; do
        [[ "${row%%|*}" == "$needle" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
begin_test "Registry rows are well formed and unique"

seen=""
for row in "${CATEGORY_REGISTRY[@]}"; do
    k="${row%%|*}"
    c="${row##*|}"
    case "$c" in
        counted|count|report-only) _pass ;;
        *) _fail "unknown class '${c}' on registry row '${row}'" ;;
    esac
    case "$seen" in
        *"|${k}|"*) _fail "duplicate registry key: ${k}" ;;
        *) _pass ;;
    esac
    seen="${seen}|${k}|"
done

# ---------------------------------------------------------------------------
begin_test "Every ledger key the code WRITES has a registry row"

written_keys="$(grep -rhoE 'catbytes_(set|add) "[a-z0-9-]+"' \
    "${PROJ_DIR}/lib" "${PROJ_DIR}/cleanup_all.sh" 2>/dev/null \
    | sed -E 's/.*"([a-z0-9-]+)"/\1/' | sort -u)"

if [[ -z "$written_keys" ]]; then
    _fail "found no catbytes_set call sites — the scan itself is broken"
else
    _pass
fi

while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    [[ "$k" == "key" ]] && continue   # the doc comment above catbytes_set()
    if registry_has_key "$k"; then
        _pass
    else
        _fail "catbytes_set \"${k}\" has no CATEGORY_REGISTRY row — the category is sized but can never be reported"
    fi
done <<< "$written_keys"

# ---------------------------------------------------------------------------
begin_test "Every ledger key the cleaners READ actually exists"

read_keys="$(grep -rhoE 'catbytes_get "[a-z0-9-]+"' \
    "${PROJ_DIR}/lib" "${PROJ_DIR}/cleanup_all.sh" 2>/dev/null \
    | sed -E 's/.*"([a-z0-9-]+)"/\1/' | sort -u)"

while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    [[ "$k" == "key" ]] && continue
    if registry_has_key "$k"; then
        _pass
    else
        _fail "catbytes_get \"${k}\" reads a key nothing ever sets — it silently returns 0 (this is how clean_logs prompted with '0 B')"
    fi
done <<< "$read_keys"

# ---------------------------------------------------------------------------
begin_test "ALL_KNOWN_CATEGORY_KEYS is derived from the registry"

derived_count=0
for row in "${CATEGORY_REGISTRY[@]}"; do
    case "${row##*|}" in counted|count) derived_count=$(( derived_count + 1 )) ;; esac
done
assert_eq "${#ALL_KNOWN_CATEGORY_KEYS[@]}" "$derived_count" \
    "the total's key list must be exactly the counted + count rows"

for k in trash user-caches app-caches user-logs system-logs npm npx pnpm brew \
         cargo pip swift-pm xcode-derived time-machine; do
    assert_array_var_contains_exact ALL_KNOWN_CATEGORY_KEYS "$k" \
        "'${k}' must stay in the totalled key list"
done

for k in browser-data mail-total system-caches app-leftovers maven android-avd xcode-archives; do
    assert_array_var_not_contains_exact ALL_KNOWN_CATEGORY_KEYS "$k" \
        "'${k}' is report-only and must not be summed into the freeable total"
done

# ---------------------------------------------------------------------------
begin_test "category_class is report-only for non-counted categories"
for k in system-caches app-leftovers maven android-avd xcode-archives; do
    assert_eq "$(category_class "$k")" "report-only" \
        "'${k}' must be report-only so counted bytes exclude it"
done

# ---------------------------------------------------------------------------
begin_test "generate_report prints a row for EVERY populated category"

MODE="dry-run"
REMOVE_MODE="quarantine"
DRY_RUN=1
TOTAL_CLEANED_BYTES=0
TOTAL_WOULD_FREE_BYTES=0
TOTAL_QUARANTINED_BYTES=0
TOTAL_QUARANTINED_ITEMS=0
TOTAL_SKIPPED_ITEMS=0
TOTAL_USER_DECISIONS_NEEDED=0
USER_DECISION_ITEMS=()
WARNINGS_LIST=()
CLEANUP_CATEGORY_OUTCOMES=""
# REPORT_FILE is readonly from config/defaults.sh; setup_artifact_isolation
# already points REPORTS_DIR at the sandbox.

# Give every registered category a non-zero value: nothing may be dropped.
for row in "${CATEGORY_REGISTRY[@]}"; do
    catbytes_set "${row%%|*}" 4096
done

generate_report "dry-run" >/dev/null 2>&1
assert_file_exists "$REPORT_FILE" "generate_report must write the report file"

report_text="$(cat "$REPORT_FILE")"
for row in "${CATEGORY_REGISTRY[@]}"; do
    label="$(category_label "${row%%|*}")"
    if [[ "$report_text" == *"| ${label} |"* ]]; then
        _pass
    else
        _fail "category '${row%%|*}' (${label}) is sized but missing from the markdown report"
    fi
done

# time-machine holds a COUNT; rendering it as bytes produced the "12 B" report.
if [[ "$report_text" == *"| Local TM Snapshots | **4096 "* ]]; then
    _pass
else
    _fail "snapshot count must be rendered with a unit, not as a byte size"
fi

if [[ "$report_text" == *"NOT included in the total"* ]]; then
    _pass
else
    _fail "report-only categories must be separated from the counted ones so the table reconciles with the total"
fi

# ---------------------------------------------------------------------------
begin_test "Every dev item the analyzer emits is reachable by a cleaner"

dev_prefixes="$(grep -oE 'FOUND_DEV_ITEMS\+=\("[a-z_]+:' "${PROJ_DIR}/lib/analyzer.sh" \
    | sed -E 's/.*"([a-z_]+):/\1/' | sort -u)"
cleaner_text="$(cat "${PROJ_DIR}/lib/cleaner.sh")"

if [[ -z "$dev_prefixes" ]]; then
    _fail "found no FOUND_DEV_ITEMS producers — the scan itself is broken"
else
    _pass
fi

while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ "$cleaner_text" == *"${p}"* ]]; then
        _pass
    else
        _fail "analyzer emits FOUND_DEV_ITEMS entry '${p}:' that no cleaner in lib/cleaner.sh ever matches — it is sized, totalled and then unreachable"
    fi
done <<< "$dev_prefixes"

# ---------------------------------------------------------------------------
begin_test "clean_ios_device_support removes paths, not 'label:path' strings"

DRY_RUN=1
MODE="dry-run"
CLEANUP_CATEGORY_OUTCOMES=""
ds_root="${SANDBOX}/Library/Developer/Xcode/iOS DeviceSupport/18.0"
mkdir -p "$ds_root"
dd if=/dev/zero of="${ds_root}/symbols.bin" bs=1024 count=64 2>/dev/null
FOUND_DEVICE_SUPPORT_ITEMS=("iOS DeviceSupport:${ds_root}")
catbytes_set "device-support" "$(path_size_bytes "$ds_root")"

ds_out="$(clean_ios_device_support 2>&1)"
if [[ "$ds_out" == *"${ds_root}"* ]]; then
    _pass
else
    _fail "the cleaner must resolve the path out of '<label>:<path>' — safe_remove on the whole string hits a non-existent path, returns 0, and the category is still reported as cleaned"
fi
if [[ "$ds_out" == *"iOS DeviceSupport:${ds_root}"* ]]; then
    _fail "the raw '<label>:<path>' entry reached safe_remove"
else
    _pass
fi

# The prompt must not advertise 0 B for a category that has a size.
if [[ "$ds_out" == *"0 B"* ]]; then
    _fail "device-support size read from the wrong ledger key (rendered 0 B)"
else
    _pass
fi

# ---------------------------------------------------------------------------
begin_test "pnpm's real store location passes path provenance"

# pnpm >= 8 on macOS stores under ~/Library/pnpm/store. The allowlist knew only
# the legacy ~/.pnpm-store, so `pnpm store path` was rejected on every run and
# 4.1 GB stayed permanently unreachable on the 2026-09-01 machine.
#
# validate_cache_path() has a blanket escape hatch for $SANDBOX/$QUARANTINE_ROOT
# so test harnesses can operate; asserting through it would be vacuous. Probe the
# root allowlist itself, with those two unset.
# The sandbox HOME lives under /var/folders, which is itself an allowed
# disposable root, so probe against a synthetic home instead.
PROBE_HOME="/Users/__pathguard_probe__"
probe_cache_root() {
    ( unset SANDBOX QUARANTINE_ROOT
      HOME="$PROBE_HOME"
      _is_within_allowed_cache_root "$1" )
}

assert_true "probe_cache_root '${PROBE_HOME}/Library/pnpm/store/v11'" \
    "Library/pnpm/store must be an allowed cache root (pnpm >= 8 default on macOS)"
assert_true "probe_cache_root '${PROBE_HOME}/.local/share/pnpm/store/v11'" \
    "the XDG pnpm store must be an allowed cache root too"
assert_true "probe_cache_root '${PROBE_HOME}/.pnpm-store'" \
    "the legacy pnpm store must keep working"

assert_false "probe_cache_root '${PROBE_HOME}/Documents'" \
    "widening the allowlist must not let user documents through"
assert_false "probe_cache_root '${PROBE_HOME}/Library/pnpmXX'" \
    "the allowlist must match a path segment, not a prefix"

print_test_summary
