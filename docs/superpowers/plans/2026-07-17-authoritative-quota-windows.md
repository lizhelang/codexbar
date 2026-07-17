# Authoritative Quota Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop inventing seven-day quota windows from `planType` and clear stale inferred windows when the latest upstream response contains only a monthly window.

**Architecture:** `WhamService` remains the upstream parsing boundary. `TokenAccount` only normalizes windows backed by duration, reset time, or usage evidence; it no longer treats a paid plan name as window evidence. Existing persistence continues to replace an account from the refreshed snapshot.

**Tech Stack:** Swift 5, Foundation, XCTest, Xcode macOS test target.

## Global Constraints

- Preserve the current UI and public model interfaces.
- Do not infer quota windows from `planType`.
- Preserve explicit zero-usage windows when upstream supplies duration or reset metadata.
- Do not change credentials, account activation, or unrelated routing behavior.
- Leave changes uncommitted unless the user explicitly requests a commit.

---

### Task 1: Lock authoritative window behavior with regression tests

**Files:**
- Modify: `codexBarTests/OpenAIAccountListLayoutTests.swift`
- Modify: `codexBarTests/WhamServiceTests.swift`

**Interfaces:**
- Consumes: `TokenAccount.usageWindowDisplays(mode:)`, `WhamService.refreshOne(account:store:usageFetcher:orgNameFetcher:oauthRefresh:)`
- Produces: regression coverage for monthly-only display and stale-window clearing.

- [x] **Step 1: Replace the old paid-plan assumption test**

Create a Team or Pro account with `primaryLimitWindowSeconds: 2_628_000` and no secondary evidence. Assert that `usageWindowDisplays(mode: .used)` contains one window with that duration and `secondaryRemainingPercent == 0`.

- [x] **Step 2: Add refresh regression coverage**

Start with a stored account containing a stale 604,800-second window plus a monthly window. Return a `WhamUsageResult` containing only the monthly window. Assert the refreshed account has `primaryLimitWindowSeconds == 2_628_000` and all secondary fields are cleared.

- [x] **Step 3: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -project codexbar.xcodeproj -scheme codexbar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:codexbarTests/OpenAIAccountListLayoutTests -only-testing:codexbarTests/WhamServiceTests
```

Expected: the new monthly-only and stale-clearing assertions fail because `resolvedSecondaryLimitWindowSeconds` still returns seven days for paid plans.

### Task 2: Remove unsupported window inference

**Files:**
- Modify: `codexBar/Models/TokenAccount.swift:493-512`

**Interfaces:**
- Consumes: stored secondary duration, reset timestamp, and used percent.
- Produces: `resolvedSecondaryLimitWindowSeconds(now:) -> Int?` without plan-based fallback.

- [x] **Step 1: Implement the minimum GREEN change**

Keep an explicit `secondaryLimitWindowSeconds`. For legacy records with secondary reset or non-zero use but no duration, retain the seven-day compatibility fallback. Delete the `plus`/`pro`/`team` branch that creates a window from the plan name alone.

- [x] **Step 2: Run focused tests**

Run the Task 1 command. Expected: all selected tests pass.

- [x] **Step 3: Run the full suite**

Run:

```bash
xcodebuild test -project codexbar.xcodeproj -scheme codexbar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: all tests pass with zero failures.

- [x] **Step 4: Review the final diff**

Confirm no UI files, credential fields, or unrelated routing branches changed. Run `git diff --check` and inspect `git status --short`.
