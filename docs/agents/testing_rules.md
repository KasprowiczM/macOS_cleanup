# Testing Rules — macOS_cleanup

## Mandatory Sequence Before Every Commit

```bash
# 1. Syntax validation (mandatory)
bash -n cleanup_all.sh lib/*.sh config/*.sh tests/*.sh

# 2. Run unit tests
bash tests/run_all.sh

# 3. Dry-run test
bash cleanup_all.sh --dry-run
```

## Test Types

### 1. `bash -n` (Syntax check)
- Bash 3.2 is strict. Syntax errors crash the entire pipeline.
- Must be run on all `.sh` files before committing.

### 2. Unit Tests (`tests/*.sh`)
- Each module in `lib/` has a corresponding `test_X.sh`.
- We use a custom lightweight testing framework in `tests/helpers.sh`.
- Use `assert_eq`, `assert_contains`, and `assert_success`.

### 3. Dry-Run Check
- Ensure that running `--dry-run` does NOT alter any file on disk.
- It should output the report JSON/Markdown cleanly without failing.

## Python Tests
- `tests/test_dev_sync_safety.py` tests the safety logic of the `dev-sync/` python wrapper.
- Run it using `python3 -m unittest tests/test_dev_sync_safety.py`.
- It verifies that the quarantine and overlay systems properly isolate files.
