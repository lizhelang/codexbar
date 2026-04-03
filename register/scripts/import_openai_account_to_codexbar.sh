#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTH_URL_SCRIPT="$ROOT_DIR/scripts/get_codexbar_auth_url.swift"
MAIL_CODE_SCRIPT="$ROOT_DIR/chatgpt-anon-register/scripts/get_latest_openai_code.applescript"
CODEXBAR_APP="${CODEXBAR_APP:-/Applications/codexbar.app}"
PLAYWRIGHT_SESSION="${PLAYWRIGHT_SESSION:-cbimp$(date +%H%M%S)}"
OPENAI_EMAIL="${OPENAI_EMAIL:-}"
OPENAI_PASSWORD="${OPENAI_PASSWORD:-}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 127
  }
}

js_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

pw() {
  playwright-cli --session "$PLAYWRIGHT_SESSION" "$@"
}

run_code() {
  local snippet="$1"
  pw run-code "$snippet" >/dev/null
}

page_url() {
  local snapshot
  snapshot="$(pw snapshot)"
  printf '%s\n' "$snapshot" | sed -n 's/^- Page URL: //p' | head -n 1
}

latest_code() {
  osascript "$MAIL_CODE_SCRIPT" 2>/dev/null | tr -d '\r\n'
}

wait_for_auth_url() {
  swift "$AUTH_URL_SCRIPT" 2>/dev/null
}

wait_for_page_match() {
  local pattern="$1"
  local timeout_secs="${2:-20}"
  local deadline=$((SECONDS + timeout_secs))
  local current=""

  while (( SECONDS < deadline )); do
    current="$(page_url || true)"
    if [[ "$current" == *"$pattern"* ]]; then
      printf '%s\n' "$current"
      return 0
    fi
    sleep 1
  done

  if [[ -n "$current" ]]; then
    printf 'timed out waiting for page containing %s, last URL: %s\n' "$pattern" "$current" >&2
  else
    printf 'timed out waiting for page containing %s\n' "$pattern" >&2
  fi
  return 1
}

wait_for_account_import() {
  local email="$1"
  local timeout_secs="${2:-30}"
  local deadline=$((SECONDS + timeout_secs))

  while (( SECONDS < deadline )); do
    if python3 - "$email" /Users/lzl/.codexbar/config.json <<'PY'
import json, sys

target = sys.argv[1]
config_path = sys.argv[2]

with open(config_path, 'r', encoding='utf-8') as fh:
    config = json.load(fh)

for provider in config.get("providers", []):
    for item in provider.get("accounts", []):
        if item.get("email") == target:
            print(json.dumps(item, ensure_ascii=False))
            raise SystemExit(0)
raise SystemExit(1)
PY
    then
      return 0
    fi
    sleep 1
  done

  printf 'timed out waiting for Codexbar to import account %s\n' "$email" >&2
  return 1
}

cleanup_playwright() {
  playwright-cli session-stop "$PLAYWRIGHT_SESSION" >/dev/null 2>&1 || true
  playwright-cli session-delete "$PLAYWRIGHT_SESSION" >/dev/null 2>&1 || true
}

trap cleanup_playwright EXIT

if [[ -z "$OPENAI_EMAIL" || -z "$OPENAI_PASSWORD" ]]; then
  printf 'usage: OPENAI_EMAIL=<email> OPENAI_PASSWORD=<password> %s\n' "$0" >&2
  exit 64
fi

require_cmd playwright-cli
require_cmd swift
require_cmd osascript
require_cmd open
require_cmd python3

osascript -e 'tell application id "lzhl.codexAppBar" to activate' >/dev/null 2>&1 || open -a "$CODEXBAR_APP"
sleep 1
open 'com.codexbar.oauth://login'

AUTH_URL=""
for _ in $(seq 1 40); do
  AUTH_URL="$(wait_for_auth_url || true)"
  if [[ -n "$AUTH_URL" ]]; then
    break
  fi
  sleep 0.25
done

if [[ -z "$AUTH_URL" ]]; then
  printf 'failed to read the Codexbar OAuth URL from the login window\n' >&2
  exit 1
fi

EMAIL_JS="$(js_escape "$OPENAI_EMAIL")"
PASSWORD_JS="$(js_escape "$OPENAI_PASSWORD")"

pw --browser chrome --headed open "$AUTH_URL" >/dev/null

run_code "(page) => page.getByRole('textbox', { name: '电子邮件地址' }).fill(\"$EMAIL_JS\")"
run_code "(page) => page.getByRole('button', { name: '继续', exact: true }).click()"
wait_for_page_match "/log-in/password" 15 >/dev/null

run_code "(page) => page.getByRole('textbox', { name: '密码' }).fill(\"$PASSWORD_JS\")"
run_code "(page) => page.getByRole('button', { name: '继续' }).click()"

CURRENT_URL="$(page_url || true)"
if [[ "$CURRENT_URL" == *"/email-verification"* ]]; then
  success=0
  for attempt in 1 2 3; do
    CODE="$(latest_code || true)"
    if [[ "$CODE" =~ ^[0-9]{6}$ ]]; then
      CODE_JS="$(js_escape "$CODE")"
      run_code "(page) => page.getByRole('textbox', { name: '验证码' }).fill(\"$CODE_JS\")"
      run_code "(page) => page.getByRole('button', { name: '继续' }).click()"
      sleep 2
      CURRENT_URL="$(page_url || true)"
      if [[ "$CURRENT_URL" != *"/email-verification"* ]]; then
        success=1
        break
      fi
    fi

    if (( attempt < 3 )); then
      run_code "(page) => page.getByRole('button', { name: '重新发送电子邮件' }).click()"
      sleep 5
    fi
  done

  if (( success == 0 )); then
    printf 'failed to get past email verification for %s\n' "$OPENAI_EMAIL" >&2
    exit 1
  fi
fi

CURRENT_URL="$(page_url || true)"
if [[ "$CURRENT_URL" == *"/sign-in-with-chatgpt/codex/consent"* ]]; then
  run_code "(page) => page.getByRole('button', { name: '继续' }).click()"
fi

wait_for_account_import "$OPENAI_EMAIL" 30

printf 'IMPORTED_EMAIL=%s\n' "$OPENAI_EMAIL"
printf 'PLAYWRIGHT_SESSION=%s\n' "$PLAYWRIGHT_SESSION"
python3 - <<'PY'
import json

with open('/Users/lzl/.codexbar/config.json', 'r', encoding='utf-8') as fh:
    config = json.load(fh)

active_provider = config.get("active", {}).get("providerId")
active_account = config.get("active", {}).get("accountId")
accounts = []

for provider in config.get("providers", []):
    if provider.get("kind") != "openai_oauth":
        continue
    for item in provider.get("accounts", []):
        accounts.append({
            "account_id": item.get("openAIAccountId") or item.get("id"),
            "email": item.get("email"),
            "active": provider.get("id") == active_provider and item.get("id") == active_account,
        })

print(json.dumps(accounts, ensure_ascii=False, indent=2))
PY
