# r/MacOSApps post draft

## Title

I built a small menu bar app for people who switch between Codex accounts or providers

## Body

I kept running into the same friction when using Codex with more than one account or an OpenAI-compatible provider: switching the active route was easy enough, but my local workflow started to feel fragmented.

So I built codexbar, a small native macOS menu bar app for that narrow part of the workflow. It lets me manage multiple OpenAI OAuth accounts, compatible providers, and API-key routes while keeping one shared `~/.codex` session/history pool.

The goal is not to replace Codex. It is to make account or provider switching affect future work without turning every route into a separate local workspace.

It currently includes:

- Manual account switching and an aggregate gateway mode for OpenAI accounts
- Multiple OpenAI-compatible providers and API keys
- Local token and cost estimates derived from Codex session files
- Controls for whether a manual switch only updates config or opens a fresh Codex instance

The project is open source: https://github.com/lizhelang/codexbar

If you use more than one Codex account or provider, what part of your switching workflow is still annoying? I am especially interested in where the current model does not match how you actually work.

## Posting notes

- Upload the three PNGs as a gallery in the order `01-overview`, `02-accounts`, `03-providers`.
- Use the `Dev Tools` flair if it is offered; otherwise use the closest available utility/productivity flair.
- Keep the GitHub link in the body, not as a separate promotional comment.
- Do not add price, discount, download-count, time-limited, or vote-request language.
