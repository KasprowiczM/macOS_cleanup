# MCP and Skills Policy

Goal: minimize context costs and reduce unused integrations.

## MCP
In `.codex/config.toml`, MCP servers are set to "allowed but lazy".
- We don't automatically load database schemas, Notion, or Slack.
- If you need them, call them explicitly.

## Skills
The `skills/` directory is constrained.
- No general web scraping skills.
- Allowed skills: only those related to shell linting, testing, and Git operations.
- This prevents the agent from hallucinating web tasks for a local macOS Bash script.
