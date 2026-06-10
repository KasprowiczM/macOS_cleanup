# Style and Coding Conventions — macOS_cleanup

## Bash 3.2 (default macOS)

- **DO NOT use**: `declare -A` (bash 4.0+), `local -n` (bash 4.3+), `mapfile`/`readarray` (bash 4.0+).
- **Arrays**: Standard indexed arrays are allowed (`declare -a`).
- **Piping**: Be aware that piping to `while read` creates a subshell. Variables set inside the `while` loop will not persist outside of it. Use process substitution `done < <(...)` instead.

## Function Patterns

### `analyze_X` vs `clean_X`
- `analyze_X`: Only reads data, calculates sizes, and outputs to the JSON/MD report structure. **Never deletes anything.**
- `clean_X`: Only executes removals based on paths identified. Uses `safe_remove()`.

## Code Format
- Indentation: 4 spaces. No tabs.
- Variables: `UPPER_CASE` for globals/constants, `lower_case` for local variables inside functions.
- Always use `local` for variables inside functions.
- Quote all variables: `"$MY_VAR"` to prevent globbing and word splitting.

## Output
- Use `log_info`, `log_warn`, `log_error` for logging to the file.
- Use `print_info`, `print_ok`, `print_warn` for UI output to the user.
