#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/state/projects.json"

NAME="${1:-}"
PURGE=${PURGE:-0}
if [[ -z "$NAME" ]]; then
  echo "Usage: $0 <project-name> [--purge]" >&2
  exit 1
fi
if [[ "${2:-}" == "--purge" ]]; then PURGE=1; fi

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

reload_caddy() {
  local cwd="$ROOT_DIR/infrastructure/caddy"
  (cd "$cwd" && sudo docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile) || true
}

main() {
  require_cmd jq
  require_cmd supabase
  if ! jq -e ".[] | select(.name==\"$NAME\")" "$STATE_FILE" >/dev/null; then
    echo "Project $NAME not found in state" >&2
    exit 1
  fi
  local path
  path="$(jq -r ".[] | select(.name==\"$NAME\") | .path" "$STATE_FILE")"

  # Stop supabase
  if [[ -d "$path" ]]; then
    (cd "$path" && sudo -E supabase stop) || true
  fi

  # Disable timer
  sudo systemctl disable --now "backup@${NAME}.timer" || true

  # Remove caddy includes + reload
  sudo rm -f "$ROOT_DIR/infrastructure/caddy/includes/api/${NAME}.caddy" || true
  sudo rm -f "$ROOT_DIR/infrastructure/caddy/includes/studio/${NAME}.caddy" || true
  reload_caddy

  # Purge data (optional)
  if [[ "$PURGE" -eq 1 && -d "$path" ]]; then
    sudo rm -rf "$path"
  fi

  # Update state
  tmp=$(mktemp)
  jq "map(select(.name != \"$NAME\"))" "$STATE_FILE" > "$tmp" && sudo mv "$tmp" "$STATE_FILE"
  echo "Destroyed project $NAME"
}

main "$@"
