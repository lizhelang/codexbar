#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDE_MY_EMAIL_SCRIPT="$ROOT_DIR/chatgpt-anon-register/scripts/create_hide_my_email.sh"
REGISTER_SCRIPT="$ROOT_DIR/chatgpt-anon-register/scripts/register_chatgpt.sh"
IMPORT_SCRIPT="$ROOT_DIR/scripts/import_openai_account_to_codexbar.sh"
CSV_PATH="$ROOT_DIR/codex.csv"
REGISTRATION_SETTLE_SECS="${REGISTRATION_SETTLE_SECS:-90}"
AUTH_URL_FILE="$(mktemp)"

LOG_EMAIL=""
LOG_PASSWORD=""
LOG_STATUS=""
LOG_URL=""

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 127
  }
}

ensure_csv_header() {
  python3 - "$CSV_PATH" <<'PY'
import csv
import os
import sys

path = sys.argv[1]
header = ["email", "password", "status", "url"]

if not os.path.exists(path):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        csv.writer(fh).writerow(header)
    raise SystemExit(0)

with open(path, "r", encoding="utf-8", newline="") as fh:
    rows = list(csv.reader(fh))

if not rows:
    rows = [header]
elif rows[0] == ["email", "password", "status"]:
    rows[0] = header
    for row in rows[1:]:
        while len(row) < 4:
            row.append("")
elif rows[0] != header:
    rows.insert(0, header)
    for row in rows[1:]:
        while len(row) < 4:
            row.append("")

with open(path, "w", encoding="utf-8", newline="") as fh:
    csv.writer(fh).writerows(rows)
PY
}

upsert_csv_row() {
  local email="$1"
  local password="$2"
  local status="$3"
  local url="$4"

  python3 - "$CSV_PATH" "$email" "$password" "$status" "$url" <<'PY'
import csv
import sys

path, email, password, status, url = sys.argv[1:]

with open(path, "r", encoding="utf-8", newline="") as fh:
    rows = list(csv.reader(fh))

if not rows:
    rows = [["email", "password", "status", "url"]]

target_index = None
if email:
    for idx in range(len(rows) - 1, 0, -1):
        row = rows[idx]
        while len(row) < 4:
            row.append("")
        if row[0] == email:
            target_index = idx
            break

if target_index is None:
    rows.append([email, password, status, url])
else:
    existing = rows[target_index]
    while len(existing) < 4:
        existing.append("")
    rows[target_index] = [
        email or existing[0],
        password if password != "" else existing[1],
        status if status != "" else existing[2],
        url if url != "" else existing[3],
    ]

with open(path, "w", encoding="utf-8", newline="") as fh:
    csv.writer(fh).writerows(rows)
PY
}

sync_csv() {
  ensure_csv_header
  if [[ -n "$LOG_EMAIL" ]]; then
    upsert_csv_row "$LOG_EMAIL" "$LOG_PASSWORD" "$LOG_STATUS" "$LOG_URL"
  fi
}

finalize_log() {
  if [[ -f "$AUTH_URL_FILE" ]]; then
    LOG_URL="$(cat "$AUTH_URL_FILE")"
  fi
  sync_csv
  rm -f "$AUTH_URL_FILE"
}

trap finalize_log EXIT

require_cmd bash
require_cmd python3

RELAY_EMAIL="$("$HIDE_MY_EMAIL_SCRIPT")"
if [[ -z "$RELAY_EMAIL" ]]; then
  LOG_STATUS="hide_my_email_failed"
  printf 'failed to create a new Hide My Email alias\n' >&2
  exit 1
fi

REGISTER_OUTPUT="$(RELAY_EMAIL="$RELAY_EMAIL" "$REGISTER_SCRIPT")"
REGISTERED_EMAIL="$(printf '%s\n' "$REGISTER_OUTPUT" | sed -n 's/^REGISTERED_EMAIL=//p' | tail -n 1)"
PASSWORD="$(printf '%s\n' "$REGISTER_OUTPUT" | sed -n 's/^PASSWORD=//p' | tail -n 1)"

if [[ -z "$REGISTERED_EMAIL" ]]; then
  LOG_STATUS="registration_parse_failed"
  printf 'failed to parse registration output\n' >&2
  printf '%s\n' "$REGISTER_OUTPUT" >&2
  exit 1
fi

LOG_EMAIL="$REGISTERED_EMAIL"
LOG_STATUS="registered"
sync_csv

LOG_PASSWORD="$PASSWORD"
sync_csv

if [[ "$REGISTRATION_SETTLE_SECS" =~ ^[0-9]+$ ]] && (( REGISTRATION_SETTLE_SECS > 0 )); then
  sleep "$REGISTRATION_SETTLE_SECS"
fi

if ! CODEX_CSV_PATH="$CSV_PATH" CODEX_CSV_EMAIL="$REGISTERED_EMAIL" CODEX_AUTH_URL_FILE="$AUTH_URL_FILE" OPENAI_EMAIL="$REGISTERED_EMAIL" OPENAI_PASSWORD="$PASSWORD" "$IMPORT_SCRIPT"; then
  if [[ -f "$AUTH_URL_FILE" ]]; then
    LOG_URL="$(cat "$AUTH_URL_FILE")"
  fi
  LOG_STATUS="import_failed"
  sync_csv
  exit 1
fi

if [[ -f "$AUTH_URL_FILE" ]]; then
  LOG_URL="$(cat "$AUTH_URL_FILE")"
fi
LOG_STATUS="success"
sync_csv

printf 'REGISTERED_EMAIL=%s\n' "$REGISTERED_EMAIL"
printf 'PASSWORD=%s\n' "$PASSWORD"
