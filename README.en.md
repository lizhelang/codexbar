# codexbar

Keep Codex Desktop context and session history in one shared pool when switching between multiple accounts or providers.

`codexbar` is a macOS menu bar utility for Codex Desktop users. It is not trying to replace Codex itself. It focuses on one practical problem:

> after switching accounts or providers, you still want to keep using the same `~/.codex` history pool instead of splitting sessions and context across multiple homes.

## What It Does

The idea is simple:

- keep one shared `~/.codex`
- do not create a separate `CODEX_HOME` for each account
- sync the active provider / account into `~/.codex/config.toml` and `~/.codex/auth.json`
- make switching affect future sessions without breaking the existing session pool

This means old sessions stay in the same history pool instead of being scattered across multiple Codex homes.

## Screenshot

<p align="center">
  <img src="./zh.png" alt="codexbar screenshot" width="720" />
</p>

## Problem It Solves

If you frequently switch between multiple OpenAI accounts, relay services, or OpenAI-compatible providers, the usual pain points are:

- configuration changes, but context feels disconnected
- session files still exist on disk, but history feels fragmented after switching
- manually editing config files is tedious and error-prone

`codexbar` is built to make that workflow less painful.

## One Shared `~/.codex` Session Pool

Many multi-account workflows isolate each account by creating a separate `CODEX_HOME`. That gives strong separation, but also creates obvious tradeoffs:

- history gets split across multiple directories
- switching can feel like your previous context disappeared
- finding the right session becomes harder

`codexbar` takes the opposite approach:

- keep a single `~/.codex`
- preserve `~/.codex/sessions` and `~/.codex/archived_sessions` as one shared history pool
- write the active provider / account into `~/.codex/config.toml` and `~/.codex/auth.json`
- let switching affect only future requests and future sessions

That is the main value of the app: switching account or provider does not mean splitting the original Codex history pool.

## Features

- Multiple OpenAI OAuth accounts
- Multiple OpenAI-compatible providers
- Multiple API-key accounts under the same provider
- Fast switching from the menu bar
- Local usage and cost estimates

Local usage and cost estimates are derived from:

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

So you can inspect token usage and estimated cost directly from local session history.

## Who This Is For

`codexbar` is useful if:

- you use both official OpenAI accounts and third-party OpenAI-compatible providers
- you keep multiple API keys under the same provider
- you do not want to edit `config.toml` manually every time you switch
- you want to preserve one shared `~/.codex` history pool and resume experience

## OpenAI Login Flow

OpenAI login currently uses a browser-based authorization flow plus manual callback paste:

1. Click `Login OpenAI`
2. Finish authorization in the browser
3. When the browser reaches `http://localhost:1455/auth/callback?...`, codexbar captures the callback automatically
4. codexbar completes token exchange and imports the account

If automatic capture fails, you can still paste the full callback URL or the raw `code` back into the window manually.

## Cost Notes

The displayed values are **local usage estimates**, not official billing numbers.

Important caveats:

- token counts are the more stable metric
- dollar values are estimated from pricing tables
- for custom OpenAI-compatible providers, displayed cost may differ from actual upstream billing

If a third-party provider uses a different pricing model than OpenAI, the dollar amount shown in the app should be treated as an approximation only.

## Project Scope

The current version focuses on:

- multi-account management
- multi-provider switching
- a shared `~/.codex` session pool
- local usage and cost summaries

This repository does not bundle any private provider, API key, or personal account configuration. You add your own configuration locally.

## Requirements

- macOS 13+
- [Codex Desktop / CLI](https://github.com/openai/codex)
- Xcode 15+ if you want to build locally

## Build Locally

```sh
git clone https://github.com/lizhelang/codexbar.git
cd codexbar
open codexbar.xcodeproj
```

Then:

1. Select your signing team in Xcode
2. Build and run the `codexbar` target

## Acknowledgements

This project references and adapts ideas and parts of the implementation from these MIT-licensed projects:

- [xmasdong/codexbar](https://github.com/xmasdong/codexbar)
- [steipete/CodexBar](https://github.com/steipete/CodexBar)

See also:

- [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)

## License

[MIT](./LICENSE)
