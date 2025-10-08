#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/state/projects.json"

MODE="${1:-table}" # table|json

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

status_for_port() {
  local port="$1"
  if ss -ltn | awk '{print $4}' | grep -q ":$port$"; then
    echo "running"
  else
    echo "stopped"
  fi
}

last_backup() {
  local name="$1"
  local dir="/var/backups/supabase/$name"
  [[ -d "$dir" ]] || { echo "-"; return; }
  ls -1 "$dir"/*.sql.gz 2>/dev/null | sort | tail -n1 | xargs -I{} basename {} 2>/dev/null || echo "-"
}

if [[ "$MODE" == "json" ]]; then
  jq '.' "$STATE_FILE"
  exit 0
fi

printf "%-16s %-10s %-10s %-10s %-24s %-8s %-24s\n" "NAME" "API" "DB" "STUDIO" "CREATED" "STATE" "LAST_BACKUP"
jq -c '.[]' "$STATE_FILE" | while read -r row; do
  name=$(jq -r '.name' <<<"$row")
  api=$(jq -r '.apiPort' <<<"$row")
  db=$(jq -r '.dbPort' <<<"$row")
  studio=$(jq -r '.studioPort' <<<"$row")
  created=$(jq -r '.createdAt' <<<"$row")
  st=$(status_for_port "$api")
  lb=$(last_backup "$name")
  printf "%-16s %-10s %-10s %-10s %-24s %-8s %-24s\n" "$name" "$api" "$db" "$studio" "$created" "$st" "$lb"
done

