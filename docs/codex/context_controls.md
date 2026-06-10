# Context Controls

## Configured in `.codex/config.toml`

- `model_auto_compact_token_limit = 240000`
- `tool_output_token_limit = 6000`
- `project_doc_max_bytes = 24576`
- `history.max_bytes = 5242880`
- `features.enable_request_compression = true`
- Shell env caps: `CODEX_TOOL_OUTPUT_MAX_LINES=200`, `CODEX_TOOL_OUTPUT_MAX_BYTES=122880`

## Operational policy

- Prefer bounded commands (`head`, `tail`, `rg --max-count`) zamiast pełnych dumpów.
- Streszczaj długie logi zamiast kopiować surowy output do kontekstu.
- Ręczna kompresja stanu sesji przy około 60% wykorzystania okna kontekstowego.
