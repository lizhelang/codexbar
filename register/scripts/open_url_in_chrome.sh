#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_CHROME_CDP_SCRIPT="$ROOT_DIR/launch_chrome_cdp.sh"

URL="https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http://localhost:1455/auth/callback&scope=openid%20profile%20email%20offline_access%20api.connectors.read%20api.connectors.invoke&code_challenge=H3PKJH355W_EqrR80exJbsFciBDpWARJvEr-gwuExM8&code_challenge_method=S256&id_token_add_organizations=true&codex_cli_simplified_flow=true&state=200E6DE9C0C24F03ADCACA25BB5621ED&originator=Codex%20Desktop"
PORT="${PORT:-9222}"
USER_DATA_DIR="${USER_DATA_DIR:-/tmp/codexbar-cdp-${PORT}}"

if [[ -z "$URL" ]]; then
  printf 'Set URL inside %s before running it.\n' "$0" >&2
  exit 64
fi

PORT="$PORT" USER_DATA_DIR="$USER_DATA_DIR" URL="$URL" "$LAUNCH_CHROME_CDP_SCRIPT"
