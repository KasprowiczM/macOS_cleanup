#!/usr/bin/env bash
# =============================================================================
# tests/test_plan_schema.sh — stdlib JSON Schema check for schemas/plan.schema.json
# Does not require the jsonschema package. Exits non-zero if any negative case passes.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

SCHEMA="${PROJ_DIR}/schemas/plan.schema.json"
SANDBOX="$(mktemp -d -t macos_cleanup_test_plan_schema.XXXXXX)"
CHECKER="${SANDBOX}/validate_plan.py"

cleanup() {
    [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}
trap cleanup EXIT

cat > "$CHECKER" << 'PY'
#!/usr/bin/env python3
"""Subset JSON Schema validator for macos-cleanup plan documents (stdlib only)."""
import json
import re
import sys


def _fail(msg):
    sys.stderr.write(msg + "\n")
    raise ValueError(msg)


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _check(instance, schema, path):
    expected_type = schema.get("type")
    if expected_type == "object":
        if not isinstance(instance, dict):
            _fail("%s: expected object" % path)
        for key in schema.get("required", []):
            if key not in instance:
                _fail("%s: missing required property %s" % (path, key))
        props = schema.get("properties", {})
        for key, value in instance.items():
            if key in props:
                _check(value, props[key], "%s.%s" % (path, key))
        return
    if expected_type == "array":
        if not isinstance(instance, list):
            _fail("%s: expected array" % path)
        item_schema = schema.get("items")
        if item_schema is not None:
            for i, item in enumerate(instance):
                _check(item, item_schema, "%s[%d]" % (path, i))
        return
    if expected_type == "string":
        if not isinstance(instance, str):
            _fail("%s: expected string" % path)
        min_len = schema.get("minLength")
        if min_len is not None and len(instance) < min_len:
            _fail("%s: string shorter than minLength %s" % (path, min_len))
        pattern = schema.get("pattern")
        if pattern is not None and re.search(pattern, instance) is None:
            _fail("%s: does not match pattern %s" % (path, pattern))
        return
    if expected_type == "integer":
        if not _is_int(instance):
            _fail("%s: expected integer, got %r" % (path, instance))
        minimum = schema.get("minimum")
        if minimum is not None and instance < minimum:
            _fail("%s: %s is below minimum %s" % (path, instance, minimum))
        return
    if expected_type == "boolean":
        if not isinstance(instance, bool):
            _fail("%s: expected boolean" % path)
        return
    if "const" in schema and instance != schema["const"]:
        _fail("%s: expected const %r" % (path, schema["const"]))
        return
    if "enum" in schema and instance not in schema["enum"]:
        _fail("%s: %r not in enum %s" % (path, instance, schema["enum"]))


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: validate_plan.py SCHEMA PLAN\n")
        return 2
    with open(sys.argv[1], encoding="utf-8") as fh:
        schema = json.load(fh)
    with open(sys.argv[2], encoding="utf-8") as fh:
        plan = json.load(fh)
    try:
        _check(plan, schema, "$")
    except ValueError:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY

write_valid_plan() {
    local dest="$1"
    python3 - "$dest" << 'PY'
import hashlib, json, sys
ops = [{
    "id": "op-0001",
    "category": "trash",
    "risk": "SAFE",
    "action": "remove_path",
    "path": "/tmp/macos-cleanup-schema-fixture",
    "command": "",
    "estimated_bytes": 1024,
    "size": 1024,
    "description": "Synthetic trash item for schema validation.",
    "recommendation": "Safe to remove in tests.",
    "rollback": True,
    "tool": "cleanup_all.sh",
}]
plan = {
    "schema_version": "1.0",
    "tool": "cleanup_all.sh",
    "tool_version": "3.0.0",
    "run_id": "schema_test",
    "generated_at": "2026-09-07T12:00:00Z",
    "checksum": hashlib.sha256(
        json.dumps(ops, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest(),
    "summary": {
        "operations": 1,
        "safe_operations": 1,
        "review_operations": 0,
        "dangerous_operations": 0,
        "safe_bytes": 1024,
        "review_bytes": 0,
        "dangerous_bytes": 0,
    },
    "operations": ops,
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(plan, fh, indent=2)
    fh.write("\n")
PY
}

mutate_plan() {
    local src="$1" dest="$2"
    shift 2
    python3 - "$src" "$dest" "$@" << 'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    plan = json.load(fh)
mode = sys.argv[3]
if mode == "bad_action":
    plan["operations"][0]["action"] = "delete_forever"
elif mode == "missing_id":
    del plan["operations"][0]["id"]
elif mode == "non_integer_bytes":
    plan["operations"][0]["estimated_bytes"] = "1024"
else:
    raise SystemExit("unknown mutation")
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(plan, fh, indent=2)
    fh.write("\n")
PY
}

VALID="${SANDBOX}/valid.json"
BAD_ACTION="${SANDBOX}/bad_action.json"
MISSING_ID="${SANDBOX}/missing_id.json"
NON_INT="${SANDBOX}/non_integer_bytes.json"

write_valid_plan "$VALID"
mutate_plan "$VALID" "$BAD_ACTION" bad_action
mutate_plan "$VALID" "$MISSING_ID" missing_id
mutate_plan "$VALID" "$NON_INT" non_integer_bytes

begin_test "valid plan with checksum, rollback, and tool fields passes"
python3 "$CHECKER" "$SCHEMA" "$VALID"
assert_eq "$?" "0" "positive fixture validates"

begin_test "bad action is rejected"
python3 "$CHECKER" "$SCHEMA" "$BAD_ACTION"
assert_neq "$?" "0" "delete_forever must fail schema check"

begin_test "missing operation id is rejected"
python3 "$CHECKER" "$SCHEMA" "$MISSING_ID"
assert_neq "$?" "0" "missing id must fail schema check"

begin_test "non-integer estimated_bytes is rejected"
python3 "$CHECKER" "$SCHEMA" "$NON_INT"
assert_neq "$?" "0" "string estimated_bytes must fail schema check"

print_test_summary
