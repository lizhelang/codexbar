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

## Screenshots

The screenshots below are **privacy-safe demo renders maintained in this repository**. They mirror the current UI structure and interaction surface, but all visible fields are rewritten to demo data, so they do not expose real accounts or tokens and do not depend on a real local `~/.codex` / `~/.codexbar` setup.

### 1. OpenAI Account View

The main menu shows the current mode, plan badge, dual 5-hour / 7-day windows, and the reset timer that actually determines when an exhausted account becomes usable again.

<p align="center">
  <img src="./docs/assets/readme-openai-accounts-demo.png" alt="codexbar OpenAI accounts demo" width="760" />
</p>

### 2. Provider Management

The provider section expands inline, so you can keep multiple OpenAI-compatible backends and multiple API-key accounts under each backend without leaving the menu bar workflow.

<p align="center">
  <img src="./docs/assets/readme-providers-demo.png" alt="codexbar providers demo" width="760" />
</p>

### 3. Settings Window

The settings window consolidates account mode, manual activation behavior, preferred Codex Desktop path, ordering rules, and update controls into one dedicated surface.

<p align="center">
  <img src="./docs/assets/readme-settings-accounts-demo.png" alt="codexbar settings demo" width="1120" />
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
- Dual OpenAI account modes: **manual switch / aggregate gateway**
- OpenAI account CSV import / export
- OpenAI account ordering: quota-weighted or manual order
- Settings for manual activation behavior and preferred Codex.app path
- Local usage and cost estimates
- Runtime version detection from GitHub Releases plus a manual "Check for Updates" entry

Local usage and cost estimates are derived from:

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

So you can inspect token usage and estimated cost directly from local session history.

The current UI also covers a few newer workflow details that the older README did not show clearly:

- OpenAI accounts can run in either **manual switch** mode or **aggregate gateway** mode
- OpenAI OAuth accounts can be imported from or exported to CSV
- Settings also let you choose whether OpenAI accounts are shown by quota-weighted ranking or your own manual order
- manual activation can either update config only or launch a fresh Codex instance
- when launching a fresh instance, you can set a preferred local Codex.app path in Settings, and invalid paths fall back to automatic detection

## Version Checks and Updates

Fixed clients now scan the GitHub Releases list at runtime and choose the **first installable stable release**. The app still performs a non-blocking check on launch, and the menu bar UI also exposes a manual "Check for Updates" action.

The current boundary is intentionally narrow:

- the stable feed is still in **guided download / install** mode
- when a newer version exists, codexbar shows it in the menu/status UI so you can continue with the matching installer asset
- runtime checks skip `draft`, `prerelease`, and any release that does not ship installable `dmg` or `zip` assets
- the current build does **not** pretend that automatic app replacement and restart are already available
- `release-feed/stable.json` is now only a one-time compatibility bridge for `1.1.8 -> 1.1.9`; it is no longer the runtime source of truth for fixed clients
- if you already installed the **first 1.1.9 build**, a same-version reissue will not appear as an upgrade automatically; you must download the reissued build manually

See also:

- [docs/update-feed-rollout.md](./docs/update-feed-rollout.md)

## Who This Is For

`codexbar` is useful if:

- you use both official OpenAI accounts and third-party OpenAI-compatible providers
- you keep multiple API keys under the same provider
- you do not want to edit `config.toml` manually every time you switch
- you want to preserve one shared `~/.codex` history pool and resume experience

## OpenAI Login Flow

OpenAI login currently uses a browser-based authorization flow with localhost callback capture plus a manual fallback. The entry point is the person-plus button in the bottom toolbar:

1. Click the login button
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
