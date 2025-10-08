#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

prompt() { local var="$1"; local msg="$2"; local def="${3:-}"; local val=""; if [[ -n "$def" ]]; then read -rp "$msg [$def]: " val || true; val="${val:-$def}"; else read -rp "$msg: " val || true; fi; printf -v "$var" '%s' "$val"; }

install_packages() {
  echo "Updating apt and installing base packages..."
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common \
    unzip zip jq iproute2 git build-essential wget rsync postgresql-client

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
  node -e "(async()=>{const bcrypt=require('bcryptjs');const s=await bcrypt.hash(process.argv[1],10);console.log(s)})().catch(e=>{console.error(e);process.exit(1)})" "$pwd"
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
  prompt DOMAIN "Root domain (e.g. example.com)"
  prompt ADMIN_PASSWORD "Admin password (for UI & Studio basic auth)"
  prompt EMAIL "Email for Let's Encrypt / Caddy"

  echo "Cloudflare R2 settings:"
  prompt R2_ACCOUNT_ID "R2 Account ID"
  prompt R2_ACCESS_KEY_ID "R2 Access Key ID"
  prompt R2_SECRET_ACCESS_KEY "R2 Secret Access Key"
  prompt R2_BUCKET "R2 Bucket name (without s3://)"
  prompt BACKUP_LOCAL_RETENTION "Local retention days" 14

  echo "Optional SMTP (for Supabase defaults; can leave blank):"
  prompt SMTP_HOST "SMTP host" ""
  prompt SMTP_PORT "SMTP port" ""
  prompt SMTP_USER "SMTP user" ""
  prompt SMTP_PASS "SMTP pass" ""
  prompt SMTP_FROM_EMAIL "SMTP from email" ""
  prompt SMTP_FROM_NAME "SMTP from name" ""

  install_packages

  # Generate bcrypt hash using node + bcryptjs
  if ! node -e 'require("bcryptjs")' >/dev/null 2>&1; then npm i -g bcryptjs >/dev/null 2>&1 || true; fi
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
