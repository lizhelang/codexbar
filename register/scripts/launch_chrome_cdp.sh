#!/usr/bin/env bash

set -euo pipefail

PORT="${PORT:-9222}"
USER_DATA_DIR="${USER_DATA_DIR:-/tmp/codexbar-cdp-${PORT}}"
URL="${URL:-about:blank}"

open -n -a "Google Chrome" --args \
  --remote-debugging-port="$PORT" \
  --user-data-dir="$USER_DATA_DIR" \
  --incognito \
  "$URL"

sleep 4
curl -sS "http://127.0.0.1:${PORT}/json/version"
