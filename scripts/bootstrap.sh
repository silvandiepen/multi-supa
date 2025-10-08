#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- UI helpers (whiptail when available) ---
have_whiptail() { command -v whiptail >/dev/null 2>&1; }
ensure_whiptail() {
  if ! have_whiptail; then
    echo "Installing whiptail for an interactive setup UI..."
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y whiptail >/dev/null 2>&1 || true
  fi
}

wt_input() {
  # args: title, message, default
  local title="$1"; shift
  local msg="$1"; shift
  local def="${1:-}"; shift || true
  local out
  out=$(whiptail --title "$title" --inputbox "$msg" 10 70 "$def" 3>&1 1>&2 2>&3) || { echo "__CANCEL__"; return 1; }
  echo "$out"
}

wt_password() {
  local title="$1"; shift
  local msg="$1"; shift
  local out
  out=$(whiptail --title "$title" --passwordbox "$msg" 10 70 3>&1 1>&2 2>&3) || { echo "__CANCEL__"; return 1; }
  echo "$out"
}

plain_prompt() { local var="$1"; local msg="$2"; local def="${3:-}"; local val=""; if [[ -n "$def" ]]; then read -rp "$msg [$def]: " val || true; val="${val:-$def}"; else read -rp "$msg: " val || true; fi; printf -v "$var" '%s' "$val"; }

install_packages() {
  echo "Updating apt and installing base packages..."
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common \
    unzip zip jq iproute2 git build-essential wget rsync postgresql-client apache2-utils

  # Docker
  if ! command -v docker >/dev/null 2>&1; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER" || true
  fi

  # Docker compose plugin
  if ! docker compose version >/dev/null 2>&1; then
    echo "Ensuring docker compose plugin available..."
    sudo apt-get install -y docker-compose-plugin || true
  fi

  # Node LTS
  if ! command -v node >/dev/null 2>&1; then
    echo "Installing Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
  fi

  # pnpm
  if ! command -v pnpm >/dev/null 2>&1; then
    sudo npm i -g pnpm
  fi

  # awscli
  if ! command -v aws >/dev/null 2>&1; then
    echo "Installing AWS CLI..."
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -o /tmp/awscliv2.zip -d /tmp
    sudo /tmp/aws/install || true
  fi

  # Supabase CLI
  if ! command -v supabase >/dev/null 2>&1; then
    echo "Installing Supabase CLI..."
    SUPA_URL=$(curl -s https://api.github.com/repos/supabase/cli/releases/latest | jq -r '.assets[] | select(.name|test("linux_amd64.tar.gz")) | .browser_download_url')
    curl -L "$SUPA_URL" -o /tmp/supabase.tar.gz
    sudo tar -C /usr/local/bin -xzf /tmp/supabase.tar.gz supabase
  fi
}

gen_bcrypt() {
  local pwd="$1"
  # Prefer Caddy's built-in bcrypt generator via Docker (no local deps)
  if command -v docker >/dev/null 2>&1; then
    local out
    out=$(sudo docker run --rm caddy:2 caddy hash-password --algorithm bcrypt --plaintext "$pwd" 2>/dev/null || true)
    if [[ -n "$out" ]]; then echo "$out"; return 0; fi
  fi
  # Fallback: htpasswd (apache2-utils) generates $2y$; normalize to $2b$
  if command -v htpasswd >/dev/null 2>&1; then
    local out
    out=$(htpasswd -nbB admin "$pwd" 2>/dev/null | cut -d: -f2 || true)
    if [[ -n "$out" ]]; then echo "${out/\$2y\$/\$2b\$}"; return 0; fi
  fi
  echo "Failed to generate bcrypt hash. Ensure Docker or apache2-utils (htpasswd) is installed." >&2
  return 1
}

write_env() {
  cat > "$ROOT_DIR/.env" <<EOF
DOMAIN=$DOMAIN
ADMIN_BCRYPT_HASH=$ADMIN_BCRYPT_HASH
R2_ACCOUNT_ID=$R2_ACCOUNT_ID
R2_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY
R2_BUCKET=s3://$R2_BUCKET
R2_REGION=auto
EMAIL=$EMAIL
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_USER=$SMTP_USER
SMTP_PASS=$SMTP_PASS
SMTP_FROM_EMAIL=$SMTP_FROM_EMAIL
SMTP_FROM_NAME=$SMTP_FROM_NAME
BACKUP_LOCAL_RETENTION=${BACKUP_LOCAL_RETENTION:-14}
EOF
}

write_supabase_env() {
  sudo tee /etc/supabase.env >/dev/null <<EOF
R2_ACCOUNT_ID=$R2_ACCOUNT_ID
R2_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY
R2_BUCKET=s3://$R2_BUCKET
R2_REGION=auto
BACKUP_LOCAL_RETENTION=${BACKUP_LOCAL_RETENTION:-14}
EOF
}

setup_dirs() {
  sudo mkdir -p /opt/caddy/includes/api /opt/caddy/includes/studio /srv /var/backups/supabase /var/log/supabase-backup
}

bring_up_caddy() {
  echo "Bringing up Caddy..."
  (cd "$ROOT_DIR/infrastructure/caddy" && DOMAIN="$DOMAIN" ADMIN_BCRYPT_HASH="$ADMIN_BCRYPT_HASH" EMAIL="$EMAIL" sudo docker compose up -d)
}

build_apps() {
  echo "Installing deps and building admin apps..."
  (cd "$ROOT_DIR" && pnpm install && pnpm --filter admin-api --filter admin-ui build)
}

setup_admin_service() {
  sudo tee /etc/systemd/system/multi-supa-admin.service >/dev/null <<EOF
[Unit]
Description=Multi Supa Admin API
After=network.target

[Service]
Type=simple
WorkingDirectory=$ROOT_DIR/apps/admin-api
EnvironmentFile=$ROOT_DIR/.env
ExecStart=/usr/bin/node $ROOT_DIR/apps/admin-api/dist/index.js
Restart=on-failure
User=$USER

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now multi-supa-admin.service
}

setup_backup_timers() {
  sudo cp "$ROOT_DIR/templates/systemd/backup@.service" /etc/systemd/system/backup@.service
  sudo cp "$ROOT_DIR/templates/systemd/backup@.timer" /etc/systemd/system/backup@.timer
  sudo systemctl daemon-reload
}

create_default_project() {
  echo "Creating default project..."
  DOMAIN="$DOMAIN" "$ROOT_DIR/scripts/create-project.sh" default || true
}

print_info() {
  echo
  echo "Bootstrap complete."
  echo "- Admin UI:  https://db.$DOMAIN"
  echo "- API:       https://api.$DOMAIN/default"
  echo "- Studio:    https://studio.$DOMAIN/default (basic auth)"
}

main() {
  echo "=== Multi-Supa Bootstrap ==="
  ensure_whiptail || true

  # Defaults (can be edited in UI)
  DOMAIN="${DOMAIN:-}"
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
  EMAIL="${EMAIL:-}"
  R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-}"
  R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
  R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
  R2_BUCKET="${R2_BUCKET:-}"
  BACKUP_LOCAL_RETENTION="${BACKUP_LOCAL_RETENTION:-14}"
  SMTP_HOST="${SMTP_HOST:-smtp.resend.com}"
  SMTP_PORT="${SMTP_PORT:-587}"
  SMTP_USER="${SMTP_USER:-}"
  SMTP_PASS="${SMTP_PASS:-}"
  SMTP_FROM_EMAIL="${SMTP_FROM_EMAIL:-}"
  SMTP_FROM_NAME="${SMTP_FROM_NAME:-}"

  if have_whiptail; then
    whiptail --title "Multi-Supa Setup" --msgbox "This wizard will install Docker, Supabase CLI, Caddy (TLS), Node, pnpm, and configure nightly backups to Cloudflare R2.\n\nYou can review and edit values before continuing." 12 70 || true

    # Collect inputs with ability to re-edit
    while true; do
      DOMAIN=$(wt_input "Domain" "Root domain (e.g., example.com)" "$DOMAIN") || exit 1
      [[ "$DOMAIN" == "__CANCEL__" ]] && exit 1
      ADMIN_PASSWORD=$(wt_password "Admin Password" "Password for Admin UI and Studio basicauth (user: admin)") || exit 1
      [[ "$ADMIN_PASSWORD" == "__CANCEL__" ]] && exit 1
      EMAIL=$(wt_input "Email" "Email for Let's Encrypt / Caddy" "$EMAIL") || exit 1
      [[ "$EMAIL" == "__CANCEL__" ]] && exit 1

      whiptail --title "Cloudflare R2" --msgbox "Enter Cloudflare R2 credentials for backups. Bucket should exist. Region is auto." 10 70 || true
      R2_ACCOUNT_ID=$(wt_input "R2 Account ID" "Your Cloudflare R2 Account ID" "$R2_ACCOUNT_ID") || exit 1
      [[ "$R2_ACCOUNT_ID" == "__CANCEL__" ]] && exit 1
      R2_ACCESS_KEY_ID=$(wt_input "R2 Access Key ID" "Your R2 Access Key ID" "$R2_ACCESS_KEY_ID") || exit 1
      [[ "$R2_ACCESS_KEY_ID" == "__CANCEL__" ]] && exit 1
      R2_SECRET_ACCESS_KEY=$(wt_input "R2 Secret Access Key" "Your R2 Secret Access Key" "$R2_SECRET_ACCESS_KEY") || exit 1
      [[ "$R2_SECRET_ACCESS_KEY" == "__CANCEL__" ]] && exit 1
      R2_BUCKET=$(wt_input "R2 Bucket" "Bucket name (without s3://)" "$R2_BUCKET") || exit 1
      [[ "$R2_BUCKET" == "__CANCEL__" ]] && exit 1
      BACKUP_LOCAL_RETENTION=$(wt_input "Local Retention" "How many days of local backups to keep" "$BACKUP_LOCAL_RETENTION") || exit 1
      [[ "$BACKUP_LOCAL_RETENTION" == "__CANCEL__" ]] && exit 1

      whiptail --title "SMTP (Optional)" --msgbox "Optional SMTP defaults for Supabase projects (Mail from, etc.). Leave blank to skip." 12 70 || true
      SMTP_HOST=$(wt_input "SMTP Host" "e.g., smtp.resend.com" "$SMTP_HOST") || exit 1
      [[ "$SMTP_HOST" == "__CANCEL__" ]] && exit 1
      SMTP_PORT=$(wt_input "SMTP Port" "e.g., 587" "$SMTP_PORT") || exit 1
      [[ "$SMTP_PORT" == "__CANCEL__" ]] && exit 1
      SMTP_USER=$(wt_input "SMTP User" "SMTP username or API key (optional)" "$SMTP_USER") || exit 1
      [[ "$SMTP_USER" == "__CANCEL__" ]] && exit 1
      SMTP_PASS=$(wt_input "SMTP Password" "SMTP password or API key (optional)" "$SMTP_PASS") || exit 1
      [[ "$SMTP_PASS" == "__CANCEL__" ]] && exit 1
      SMTP_FROM_EMAIL=$(wt_input "From Email" "From email address (optional)" "$SMTP_FROM_EMAIL") || exit 1
      [[ "$SMTP_FROM_EMAIL" == "__CANCEL__" ]] && exit 1
      SMTP_FROM_NAME=$(wt_input "From Name" "From name (optional)" "$SMTP_FROM_NAME") || exit 1
      [[ "$SMTP_FROM_NAME" == "__CANCEL__" ]] && exit 1

      SUMMARY="Domain: $DOMAIN\nEmail: $EMAIL\n\nR2 Account ID: $R2_ACCOUNT_ID\nR2 Bucket: $R2_BUCKET\nLocal retention (days): $BACKUP_LOCAL_RETENTION\n\nSMTP Host: ${SMTP_HOST:-<none>}\nSMTP Port: ${SMTP_PORT:-<none>}\nSMTP User: ${SMTP_USER:-<none>}\nSMTP From: ${SMTP_FROM_NAME:-}${SMTP_FROM_NAME:+ }<${SMTP_FROM_EMAIL:-}>"
      if whiptail --title "Confirm Settings" --yesno "$SUMMARY\n\nProceed with installation?" 20 78; then
        break
      else
        # Offer edit menu
        SEL=$(whiptail --title "Edit Which Field?" --menu "Select a field to edit" 20 78 12 \
          dom "Domain" \
          eml "Email" \
          pwd "Admin Password" \
          r2a "R2 Account ID" \
          r2k "R2 Access Key ID" \
          r2s "R2 Secret Access Key" \
          r2b "R2 Bucket" \
          r2r "Local Retention Days" \
          s1 "SMTP Host" \
          s2 "SMTP Port" \
          s3 "SMTP User" \
          s4 "SMTP Password" \
          s5 "SMTP From Email" \
          s6 "SMTP From Name" 3>&1 1>&2 2>&3) || continue
        case "$SEL" in
          dom) DOMAIN=$(wt_input "Domain" "Root domain" "$DOMAIN") || true ;;
          eml) EMAIL=$(wt_input "Email" "Email for Let's Encrypt" "$EMAIL") || true ;;
          pwd) ADMIN_PASSWORD=$(wt_password "Admin Password" "Password for Admin UI and Studio") || true ;;
          r2a) R2_ACCOUNT_ID=$(wt_input "R2 Account ID" "Cloudflare R2 Account ID" "$R2_ACCOUNT_ID") || true ;;
          r2k) R2_ACCESS_KEY_ID=$(wt_input "R2 Access Key ID" "Your R2 Access Key ID" "$R2_ACCESS_KEY_ID") || true ;;
          r2s) R2_SECRET_ACCESS_KEY=$(wt_input "R2 Secret Access Key" "Your R2 Secret" "$R2_SECRET_ACCESS_KEY") || true ;;
          r2b) R2_BUCKET=$(wt_input "R2 Bucket" "Bucket name (no s3://)" "$R2_BUCKET") || true ;;
          r2r) BACKUP_LOCAL_RETENTION=$(wt_input "Local Retention" "Days to keep local backups" "$BACKUP_LOCAL_RETENTION") || true ;;
          s1) SMTP_HOST=$(wt_input "SMTP Host" "e.g., smtp.resend.com" "$SMTP_HOST") || true ;;
          s2) SMTP_PORT=$(wt_input "SMTP Port" "e.g., 587" "$SMTP_PORT") || true ;;
          s3) SMTP_USER=$(wt_input "SMTP User" "Optional" "$SMTP_USER") || true ;;
          s4) SMTP_PASS=$(wt_input "SMTP Password" "Optional" "$SMTP_PASS") || true ;;
          s5) SMTP_FROM_EMAIL=$(wt_input "From Email" "Optional" "$SMTP_FROM_EMAIL") || true ;;
          s6) SMTP_FROM_NAME=$(wt_input "From Name" "Optional" "$SMTP_FROM_NAME") || true ;;
        esac
      fi
    done
  else
    # Fallback to plain prompts
    plain_prompt DOMAIN "Root domain (e.g. example.com)"
    plain_prompt ADMIN_PASSWORD "Admin password (for UI & Studio basic auth)"
    plain_prompt EMAIL "Email for Let's Encrypt / Caddy"

    echo "Cloudflare R2 settings:"
    plain_prompt R2_ACCOUNT_ID "R2 Account ID"
    plain_prompt R2_ACCESS_KEY_ID "R2 Access Key ID"
    plain_prompt R2_SECRET_ACCESS_KEY "R2 Secret Access Key"
    plain_prompt R2_BUCKET "R2 Bucket name (without s3://)"
    plain_prompt BACKUP_LOCAL_RETENTION "Local retention days" 14

    echo "Optional SMTP (for Supabase defaults; can leave blank):"
    plain_prompt SMTP_HOST "SMTP host" "$SMTP_HOST"
    plain_prompt SMTP_PORT "SMTP port" "$SMTP_PORT"
    plain_prompt SMTP_USER "SMTP user" "$SMTP_USER"
    plain_prompt SMTP_PASS "SMTP pass" "$SMTP_PASS"
    plain_prompt SMTP_FROM_EMAIL "SMTP from email" "$SMTP_FROM_EMAIL"
    plain_prompt SMTP_FROM_NAME "SMTP from name" "$SMTP_FROM_NAME"
  fi

  install_packages

  # Generate bcrypt hash using Docker caddy or htpasswd
  ADMIN_BCRYPT_HASH=$(gen_bcrypt "$ADMIN_PASSWORD")

  setup_dirs
  write_env
  write_supabase_env
  setup_backup_timers
  bring_up_caddy
  build_apps
  setup_admin_service
  create_default_project
  print_info
}

main "$@"
