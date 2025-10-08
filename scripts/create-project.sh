#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/state/projects.json"
API_TMPL="$ROOT_DIR/templates/api.caddy.tmpl"
STUDIO_TMPL="$ROOT_DIR/templates/studio.caddy.tmpl"

PROJECT_NAME="${1:-}"
if [[ -z "${PROJECT_NAME}" ]]; then
  echo "Usage: $0 <project-name>" >&2
  exit 1
fi

ensure_json_file() {
  if [[ ! -f "$STATE_FILE" ]]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    echo '[]' > "$STATE_FILE"
  fi
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

ensure_dirs() {
  sudo mkdir -p "$ROOT_DIR/infrastructure/caddy/includes/api"
  sudo mkdir -p "$ROOT_DIR/infrastructure/caddy/includes/studio"
  sudo mkdir -p /srv
  sudo mkdir -p /var/backups/supabase
  sudo mkdir -p /var/log/supabase-backup
}

project_exists() {
  jq -e ".[] | select(.name==\"$PROJECT_NAME\")" "$STATE_FILE" >/dev/null 2>&1
}

next_index_and_ports() {
  # Port allocation rule: base + 1000*k
  local idx=0
  local base_api=54321
  local base_db=54322
  local base_studio=54323
  local base_mailpit=54324

  while true; do
    local api=$((base_api + 1000*idx))
    local db=$((base_db + 1000*idx))
    local studio=$((base_studio + 1000*idx))
    local mailpit=$((base_mailpit + 1000*idx))

    if ! ss -ltn | awk '{print $4}' | grep -E ":($api|$db|$studio|$mailpit)$" >/dev/null 2>&1 \
       && [[ ! -d "/srv/supabase-$PROJECT_NAME" ]]; then
      echo "$idx $api $db $studio $mailpit"
      return 0
    fi
    idx=$((idx+1))
  done
}

render_caddy_include() {
  local tmpl="$1"; shift
  local out="$1"; shift
  local project="$1"; shift
  local api_port="$1"; shift || true
  local studio_port="$1"; shift || true
  local content
  content="$(cat "$tmpl")"
  content="${content//\{project\}/$project}"
  if [[ -n "${api_port:-}" ]]; then content="${content//\{api_port\}/$api_port}"; fi
  if [[ -n "${studio_port:-}" ]]; then content="${content//\{studio_port\}/$studio_port}"; fi
  echo "$content" | sudo tee "$out" >/dev/null
}

reload_caddy() {
  local cwd
  cwd="$ROOT_DIR/infrastructure/caddy"
  if [[ -f "$cwd/docker-compose.yml" ]]; then
    (cd "$cwd" && sudo docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile) || {
      echo "Caddy reload via exec failed; trying SIGHUP" >&2
      sudo docker ps --filter name=caddy --format '{{.ID}}' | head -n1 | xargs -r -I{} sudo docker kill -s SIGUSR1 {}
    }
  fi
}

supabase_ports_patch() {
  local cfg="$1"
  local api_port="$2"
  local db_port="$3"
  local studio_port="$4"
  # Update config.toml simple replaces
  sed -i "s/\(api_url = \"http:\/\/localhost:\)\([0-9]\+\)/\1$api_port/" "$cfg" || true
  sed -i "s/\(db_port = \)\([0-9]\+\)/\1$db_port/" "$cfg" || true
  sed -i "s/\(studio_port = \)\([0-9]\+\)/\1$studio_port/" "$cfg" || true
}

inject_smtp_env() {
  local envfile="$1"
  [[ -f "$ROOT_DIR/.env" ]] || return 0
  # Pull SMTP_* from root .env and append if present
  grep -E '^SMTP_' "$ROOT_DIR/.env" | sudo tee -a "$envfile" >/dev/null || true
}

main() {
  require_cmd jq
  require_cmd ss
  require_cmd supabase
  require_cmd docker
  ensure_dirs
  ensure_json_file

  if project_exists; then
    echo "Project '$PROJECT_NAME' already exists in state." >&2
    exit 1
  fi

  read -r IDX API_PORT DB_PORT STUDIO_PORT MAILPIT_PORT < <(next_index_and_ports)
  local proj_dir="/srv/supabase-$PROJECT_NAME"

  if [[ -d "/srv/supabase-base" ]]; then
    sudo rsync -a "/srv/supabase-base/" "$proj_dir/"
  else
    # If any existing project, use it as base
    local first
    first="$(ls -d /srv/supabase-* 2>/dev/null | head -n1 || true)"
    if [[ -n "$first" && -d "$first" ]]; then
      sudo rsync -a "$first/" "$proj_dir/"
    else
      # Initialize a fresh supabase stack
      sudo mkdir -p "$proj_dir"
      sudo chown -R "$USER":"$USER" "$proj_dir"
      (cd "$proj_dir" && supabase init --project-id "$PROJECT_NAME" >/dev/null 2>&1 || true)
    fi
  fi

  # Patch ports in config.toml if present
  if [[ -f "$proj_dir/supabase/config.toml" ]]; then
    sudo sed -i "s/\r$//" "$proj_dir/supabase/config.toml"
    supabase_ports_patch "$proj_dir/supabase/config.toml" "$API_PORT" "$DB_PORT" "$STUDIO_PORT" || true
  fi

  # Ensure .env exists and add SMTP defaults
  sudo touch "$proj_dir/.env"
  inject_smtp_env "$proj_dir/.env"

  # Start project
  (cd "$proj_dir" && sudo -E supabase start) || { echo "Failed to start supabase for $PROJECT_NAME" >&2; exit 1; }

  # Write Caddy includes
  render_caddy_include "$API_TMPL" "$ROOT_DIR/infrastructure/caddy/includes/api/$PROJECT_NAME.caddy" "$PROJECT_NAME" "$API_PORT"
  render_caddy_include "$STUDIO_TMPL" "$ROOT_DIR/infrastructure/caddy/includes/studio/$PROJECT_NAME.caddy" "$PROJECT_NAME" "" "$STUDIO_PORT"
  reload_caddy

  # Update state
  local createdAt
  createdAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp=$(mktemp)
  jq --arg name "$PROJECT_NAME" \
     --arg path "$proj_dir" \
     --arg createdAt "$createdAt" \
     --argjson api $API_PORT --argjson db $DB_PORT --argjson studio $STUDIO_PORT --argjson mailpit $MAILPIT_PORT \
     '. + [{name: $name, path: $path, createdAt: $createdAt, enabled: true, apiPort: $api, dbPort: $db, studioPort: $studio, mailpitPort: $mailpit, lastBackup: null}]' \
     "$STATE_FILE" > "$tmp" && sudo mv "$tmp" "$STATE_FILE"

  # Enable backup timer
  sudo systemctl enable --now "backup@${PROJECT_NAME}.timer" || true

  echo "Created project $PROJECT_NAME"
  echo "API:    https://api.${DOMAIN:-<domain>}/$PROJECT_NAME"
  echo "Studio: https://studio.${DOMAIN:-<domain>}/$PROJECT_NAME"
}

main "$@"
