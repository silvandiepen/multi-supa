#!/usr/bin/env bash
set -euo pipefail

NAME="${1:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/state/projects.json"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

require_cmd jq
require_cmd pg_dump
require_cmd gzip
require_cmd aws

RETENTION_DAYS="${BACKUP_LOCAL_RETENTION:-14}"
R2_BUCKET="${R2_BUCKET:-}"

backup_one() {
  local name="$1"
  local port
  port="$(jq -r ".[] | select(.name==\"$name\") | .dbPort" "$STATE_FILE")"
  if [[ -z "$port" || "$port" == "null" ]]; then
    echo "Unknown project $name" >&2; return 1
  fi
  local ts
  ts="$(date +%F_%H-%M-%S)"
  local outdir="/var/backups/supabase/$name"
  sudo mkdir -p "$outdir"
  local outfile="$outdir/${ts}.sql.gz"
  local logdir="/var/log/supabase-backup"
  sudo mkdir -p "$logdir"
  local logfile="$logdir/${name}.log"
  {
    echo "[$(date -u)] Starting backup for $name on port $port"
    PGPASSWORD=postgres pg_dump -h 127.0.0.1 -p "$port" -U postgres -d postgres | gzip > "$outfile"
    echo "[$(date -u)] Local backup written: $outfile"
    if [[ -n "$R2_BUCKET" ]]; then
      AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION="${R2_REGION:-auto}" \
      aws s3 cp "$outfile" "${R2_BUCKET}/$name/" --endpoint-url "https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com" && \
      echo "[$(date -u)] Uploaded to R2: ${R2_BUCKET}/$name/"
    else
      echo "[$(date -u)] Skipping R2 upload; R2_BUCKET not set"
    fi
    # Retention: delete files older than N days
    find "$outdir" -type f -name '*.sql.gz' -mtime +"$RETENTION_DAYS" -print -delete || true
    echo "[$(date -u)] Retention applied: ${RETENTION_DAYS} days"
  } | sudo tee -a "$logfile" >/dev/null

  # Update lastBackup in state
  tmp=$(mktemp)
  jq --arg name "$name" --arg t "$ts" 'map(if .name==$name then .lastBackup=$t else . end)' "$STATE_FILE" > "$tmp" && sudo mv "$tmp" "$STATE_FILE"
}

main() {
  if [[ -z "$NAME" || "$NAME" == "all" ]]; then
    jq -r '.[].name' "$STATE_FILE" | while read -r n; do backup_one "$n"; done
  else
    backup_one "$NAME"
  fi
}

main "$@"
