# codexbar

Keep Codex Desktop context and session history in one shared `~/.codex` pool while switching accounts or providers.

`codexbar` is a macOS menu bar utility for Codex Desktop users. It is not trying to replace Codex. It narrows in on the part of the workflow where account or provider switching tends to fragment context and session continuity.

See the [2.0.1 release notes](./docs/releases/2.0.1.md) for the complete changes to page navigation, Limits and multi-tool account management.

> Switching account or provider should not mean splitting your original Codex session pool into multiple homes.

## At A Glance

- Keep one shared `~/.codex` instead of creating a separate `CODEX_HOME` per account
- Manage OpenAI OAuth, OpenAI-compatible providers, and multiple API keys from the menu bar
- Support both **manual switch** and **aggregate gateway** modes for OpenAI accounts
- Read local usage from Codex, Claude Code, OpenCode, and DeepSeek Harness; sync Cursor usage automatically, with CSV import available
- Choose a tool first, then switch between Today / This month / Total (with last 7 / 30 days available), and Tokens / Cost in the menu bar
- Make switching affect future sessions without breaking the existing history pool

## Problem It Solves

If you switch often between official OpenAI accounts, relay backends, or OpenAI-compatible providers, the common failure mode is always similar:

- configuration changes, but context feels disconnected
- session files still exist on disk, but history feels fragmented after switching
- manually editing config files is tedious and error-prone

`codexbar` is meant to make that switching workflow feel like one continuous Codex workspace instead of several loosely related homes.

## Product Overview

This poster-style overview focuses on the core workflow: use `codexbar` from the macOS menu bar to switch OpenAI accounts, compatible providers, and local gateway mode while keeping one shared `~/.codex` session pool.

<p align="center">
  <img src="./marketing/twitter-poster.png" alt="codexbar product poster" width="1120" />
</p>

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
- Usage views for Codex and other AI tools
- Runtime version detection from GitHub Releases plus a manual "Check for Updates" entry

### Usage Sources and Views

The menu bar switches between tools, Today / This month / Total (with last 7 / 30 days available), and Tokens / Cost. "All tools" totals the sources that have been read. Each tool keeps its own usage records; switching a Codex account or provider does not attribute another tool's usage to Codex. The all-time total covers available history, while the detail chart shows the last 30 days.

| Tool | Usage source |
| --- | --- |
| Codex | Local `~/.codex/sessions` and `~/.codex/archived_sessions` |
| Claude Code | Local Claude Code session records |
| OpenCode | Local OpenCode database or legacy records |
| DeepSeek Harness | Local DSH session records |
| Cursor | Read the local Cursor sign-in state and sync from Cursor's usage endpoint; CSV import from the Usage page is also available |

The app scans Claude Code, OpenCode, and DeepSeek Harness locally without changing their records. Local history remains app-wide when records do not identify a reliable account. Cursor supports read-only desktop discovery and manual Cookie/JWT accounts, with separate usage, quota and plan data for each stable user ID. The dashboard projects the selected monitoring account without changing Cursor's desktop sign-in. CSV imports belong to that selected account and replace its previous history. Account metadata and usage caches contain no credentials; managed credentials are stored separately in owner-readable/writable files and are never logged. Cursor's private endpoints may change; a failed sync keeps that account's previous history and displays the failure.

Codex history uses the local `~/.codexbar/cost-usage.sqlite` derived index. It resumes from changed JSONL bytes in bounded background passes, keeps the last available result during a scan, and does not modify the original sessions. **Codex local sessions** count tokens as `input + cached_input + output`; other tools use the usage fields reported in their own records. The cross-tool cache at `~/.codexbar/tool-usage-summary.json` stores daily usage aggregates, source status, and timestamps only; it does not store transcript content or login credentials.

The figures cover only the available local records, Cursor endpoint, or export. They are not live usage or official billing totals. If a source has no trustworthy cost, the Cost view shows the known portion and marks it incomplete; Tokens remain available separately.

The current UI also covers a few newer workflow details that the older README did not show clearly:

- OpenAI accounts can run in either **manual switch** mode or **aggregate gateway** mode
- OpenAI OAuth accounts can be imported from or exported to CSV
- Settings also let you choose whether OpenAI accounts are shown by quota-weighted ranking or your own manual order

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

## Star History

<p align="center">
  <a href="https://star-history.com/#lizhelang/codexbar&Date">
    <picture>
      <source
        media="(prefers-color-scheme: dark)"
        srcset="https://api.star-history.com/svg?repos=lizhelang/codexbar&type=Date&theme=dark"
      />
      <source
        media="(prefers-color-scheme: light)"
        srcset="https://api.star-history.com/svg?repos=lizhelang/codexbar&type=Date"
      />
      <img
        alt="codexbar Star History Chart"
        src="https://api.star-history.com/svg?repos=lizhelang/codexbar&type=Date"
      />
    </picture>
  </a>
</p>

## OpenAI Login Flow

OpenAI login currently uses a browser-based authorization flow with localhost callback capture plus a manual fallback. Open **Limits → + → Add Codex account** in the header:

1. Select "Add Codex account"
2. Finish authorization in the browser
3. When the browser reaches `http://localhost:1455/auth/callback?...`, codexbar captures the callback automatically
4. codexbar completes token exchange and imports the account

If automatic capture fails, you can still paste the full callback URL or the raw `code` back into the window manually.

A single dropdown in the header switches between Limits, Statistics, Tools, Models, Projects, Sessions, Devices and Trends, opening Limits by default. The former Management page is now Limits, and dashboard Home is now Statistics. The mode switch and bottom navigation have been replaced by this menu. Page Navigation settings control page order and visibility, with Limits and Statistics always available. Saved custom order and Statistics module preferences are preserved.

Limits shows total tokens, estimated usage cost and source status for the selected period, with date and metric controls. Tools share a flat section layout. Use "Reorder" and the arrow buttons to arrange and save their order. All five headers expand or collapse details in place and remember their state. Collapsed Codex keeps the current account, remaining quota, model, reasoning effort, service tier and context controls visible. Expand it to manage all accounts, quota windows, GPT Reserve, reset times and reset cards, with switching, refresh, reauthorization and removal actions. "Connect provider" remains available when Codex is collapsed; existing third-party providers are managed inside the expanded section.

Claude Code, OpenCode, Cursor and DeepSeek Harness also show quotas, balances and source status in Limits. Expand a tool in place to discover connections, add supported credentials and query each connection. Account management stays in the same section. Directory and CSV controls remain in Collection Settings. The "…" menu retains refresh, collection controls and CSV import, with View Usage directly available. Paused tools can still be enabled on the Limits page.

| Tool | Native account connections |
| --- | --- |
| Codex | Existing OAuth accounts, per-account limits, reset cards, routing and third-party providers |
| Cursor | Desktop discovery, manual Cookie/JWT accounts, separate usage and limits, renaming, pause, dashboard selection and manual credential replacement/removal |
| Claude Code | Local OAuth discovery or a web sessionKey with explicit organization selection; subscription limits and credential clearing; ordinary API keys have no subscription quota |
| OpenCode | Discovered Go connections and named API key/web Cookie profiles; rename, reorder, pause, credential transfer and removal; separate Go limits or web balances |
| DeepSeek Harness | Existing provider balance snapshots, explicitly bound official environment keys, and manual official API key save/clear and balance queries |

DSH distinguishes saved balance snapshots from live API queries. Legacy and current DeepSeek identifiers merge only when their credential-source identity matches; equal amounts do not establish account identity. Reloading a snapshot keeps its original timestamp. Live balances require a key explicitly bound to the official endpoint. Automatically discovered DSH sources can be hidden and restored without deleting DSH configuration, credentials or historical snapshots.

Provider-specific account and quota flows adapt Token Monitor's implementation, with complete MIT attribution and licenses retained in source and app resources; see [Third-Party Notices](./THIRD_PARTY_NOTICES.md). Balance is not a subscription percentage, and shared local history is not presented as a manual account's bill.

## Cost Notes

The displayed values are **views of local records and imported usage**, not official billing numbers.

Important caveats:

- token counts are the more stable metric
- Codex dollar values are estimated from model pricing tables; other tools use costs reported in their local records, Cursor's usage endpoint, or its export when available
- local history is indexed in `~/.codexbar/cost-usage.sqlite`; append-only session updates resume from persisted byte offsets instead of rescanning complete files
- large first-time history imports catch up in bounded background passes while the app keeps the last known good snapshot and shows the real scan state
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

This project references ideas, implementation, and visual design from these MIT-licensed projects:

- [xmasdong/codexbar](https://github.com/xmasdong/codexbar)
- [steipete/CodexBar](https://github.com/steipete/CodexBar)
- [Javis603/token-monitor](https://github.com/Javis603/token-monitor) (visual hierarchy reference for the menu and settings)

See also:

- [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)

## License

[MIT](./LICENSE)
