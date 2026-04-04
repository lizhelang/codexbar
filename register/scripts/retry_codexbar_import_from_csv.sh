#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV_PATH="$ROOT_DIR/codex.csv"
IMPORT_SCRIPT="$ROOT_DIR/scripts/import_openai_account_to_codexbar.sh"
EMAIL_FILTER="${EMAIL_FILTER:-}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 127
  }
}

require_cmd python3

readarray -t TARGET < <(
  python3 - "$CSV_PATH" "$EMAIL_FILTER" <<'PY'
import csv
import json
import os
import sys

csv_path, email_filter = sys.argv[1:]
cfg_path = os.path.expanduser('~/.codexbar/config.json')

with open(cfg_path, 'r', encoding='utf-8') as fh:
    cfg = json.load(fh)

imported = {
    account.get('email')
    for provider in cfg.get('providers', [])
    if provider.get('kind') == 'openai_oauth'
    for account in provider.get('accounts', [])
}

with open(csv_path, 'r', encoding='utf-8', newline='') as fh:
    rows = list(csv.DictReader(fh))

for row in reversed(rows):
    email = row.get('email', '')
    password = row.get('password', '')
    if not email or not password:
        continue
    if email_filter and email != email_filter:
        continue
    if email in imported:
        continue
    print(email)
    print(password)
    raise SystemExit(0)

raise SystemExit(1)
PY
)

if (( ${#TARGET[@]} < 2 )); then
  if [[ -n "$EMAIL_FILTER" ]]; then
    printf 'no pending Codexbar import account found in %s for %s\n' "$CSV_PATH" "$EMAIL_FILTER" >&2
  else
    printf 'no pending Codexbar import account found in %s\n' "$CSV_PATH" >&2
  fi
  exit 1
fi

OPENAI_EMAIL="${TARGET[0]}" OPENAI_PASSWORD="${TARGET[1]}" "$IMPORT_SCRIPT"
