# UX/DX Model: SAFE / REVIEW / DANGEROUS

## Goal
This document describes the target UX/DX language for macOS cleanup. The model must be understandable to the end user and safely implementable by developers/agents.

## Core Concepts

### 1. SAFE
Data that is strictly recreatable.
- **Examples**: Build caches, `~/Library/Caches` subfolders known to only store thumbnails/temp web assets, old logs.
- **UX**: User can confidently run `--auto-safe`. 
- **DX**: Agents can script automatic removal via `safe_remove()` knowing it defaults to quarantine.

### 2. REVIEW
Data that can be recreated, but carries a heavy cost in time, bandwidth, or lost diagnostic state.
- **Examples**: JetBrains IDE caches (requires long re-indexing), Docker build caches, large offline ML models, Maven `.m2` repository.
- **UX**: Exposed in the interactive report. User must explicitly agree.
- **DX**: Skips automatic deletion. Output is strictly for `plan` and `report_only`.

### 3. DANGEROUS
Data critical to the user's workflow. Deletion causes permanent, non-recreatable loss.
- **Examples**: Apple Mail data, Browser Profiles (cookies, history, passwords), Keychain, Documents, active app preferences.
- **UX**: Script blocks deletion entirely or warns vehemently.
- **DX**: Guardrailed inside `is_protected_path()`. Hard-coded rejection.

## Workflow Phases
1. **Analyze**: Read-only scan. Generates a markdown report mapping paths to the risk categories.
2. **Plan**: Generates a JSON manifest of what *would* be removed, categorized by risk.
3. **Apply**: Takes a JSON plan or uses `--auto-safe` to execute safe deletions into quarantine.
