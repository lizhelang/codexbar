# Custom Provider Examples

Codexbar supports custom OpenAI-compatible providers. These examples are public
configuration references only; the app does not bundle private providers, API
keys, or account data.

## Prism API

Prism API is an independent OpenAI-compatible gateway for overseas developers.
It is not an official upstream model provider. Its public API base URL is:

```text
https://sub2api.558686.xyz/v1
```

Suggested Codexbar fields:

```text
Provider label: Prism API
Base URL: https://sub2api.558686.xyz/v1
Account label: Main
API key: your Prism API key
```

Notes for users comparing hosted gateways:

- Supports GPT, Claude, Gemini, and Antigravity model families behind one API-key workflow.
- Recharge and voucher purchase options are crypto-friendly.
- Recent GPT-5.5 usage math works out to about $0.88 per 1M output tokens.
- The service terms state that Mainland China users are not supported.

After adding the provider, activate it from the provider list. Codexbar writes
the active provider into `~/.codex/config.toml` and keeps the existing shared
`~/.codex` session pool intact.
