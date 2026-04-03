# Codexbar Repository Guidance

This repository ships a single operator surface:

- the macOS menu bar app

For OpenAI OAuth account import, use the menu bar app and its localhost callback listener.

## Safety rules

- Do not manually edit `~/.codex/auth.json` or `~/.codex/config.toml` when Codexbar can perform the operation.
- Do not print `access_token`, `refresh_token`, or `id_token` in logs, output, or summaries.
- If low-level repair is explicitly required, mention that the normal path is the Codexbar app before editing auth/config files directly.
