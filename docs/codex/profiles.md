# Codex Profiles

## Target architecture

- `default-worker` (default): `gpt-5.3-codex`, reasoning `medium`.
- `orchestrator`: `gpt-5.3-codex`, reasoning `high`, deleguje do advisor/workers.
- `advisor`: `gpt-5.4`, reasoning `high`, `read-only` + `approval_policy = "never"`.
- `worker-fast`: `gpt-5.4-mini`, reasoning `low`, szybkie transformacje i boilerplate.
- `worker-tests`: `gpt-5.2`, reasoning `medium`, testy, QA, dokumentacja techniczna.
- `worker-docs`: `gpt-5.4-mini`, reasoning `medium`, małe aktualizacje dokumentacji.

## Rules

- Orchestrator planuje i deleguje; implementuje lokalnie tylko gdy to szybsze od delegacji.
- Advisor nie tworzy patchy i nie uruchamia operacji modyfikujących pliki.
- Workerzy dostają zadania o wąskim zakresie i jasno określonych plikach odpowiedzialności.

## Activation

- CLI: `codex --profile default-worker` (lub `orchestrator`, `advisor`, `worker-fast`).
- App Codex: wybierz ten sam profil w profile pickerze; profile są współdzielone przez `.codex/config.toml` w katalogu projektu.
