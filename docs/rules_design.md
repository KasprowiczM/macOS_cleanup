# Documentation of the cleanup_rules.yaml structure

## Purpose
Describes the structure of the `cleanup_rules.yaml` file, how the `analyzer.sh` script interprets rules, and constraints on rule definitions.

## YAML Structure

The root is the `rules` list. Each item is a single rule.

```yaml
rules:
  - id: "rule_001"
    category: "caches"
    name: "System Cache"
    risk: "REVIEW"
    paths:
      - "~/Library/Caches"
    description: "Ogólny katalog cache. Może zawierać bardzo duże dane aplikacji."
    recommendation: "Sprawdź ręcznie przed usunięciem."
```

## Fields

- `id`: Unique identifier (string). Pattern: `rule_[0-9]{3}`.
- `category`: Grouping category (e.g., `caches`, `logs`, `dev`, `docker`).
- `name`: Short, human-readable name.
- `risk`: Risk level. Allowed values: `SAFE`, `REVIEW`, `DANGEROUS`.
- `paths`: List of glob patterns or absolute paths. Variables like `$HOME` or `~` are expanded.
- `description`: Detailed explanation of what the path contains.
- `recommendation`: Advice to the user on what to do.

## Validation
- The `tests/test_analyzer.sh` validates that all rules parse correctly and no required fields are missing.
- Duplicate `id` values are forbidden.
- Unknown `risk` values fail the pipeline.
