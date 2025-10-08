#!/usr/bin/env bash
set -euo pipefail

# Remote bootstrap installer
# - Downloads the repo tarball to DEST (default: /monorepo)
# - Opens 80/443 if ufw is active
# - Runs scripts/bootstrap.sh interactively
#
# Usage examples:
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/scripts/remote-bootstrap.sh | bash -s -- \
#     --repo https://github.com/<user>/<repo> --branch main --dest /monorepo
#

REPO_URL=""
BRANCH="main"
DEST="/monorepo"
OPEN_PORTS=1

usage() {
  cat <<EOF
Remote bootstrap installer

Options:
  --repo <url>      GitHub repo URL (e.g., https://github.com/user/repo) [required]
  --branch <name>   Branch to download (default: main)
  --dest <path>     Destination directory (default: /monorepo)
  --no-open-ports   Do not open ufw ports 80/443 automatically

Example:
  curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/scripts/remote-bootstrap.sh | bash -s -- \
    --repo https://github.com/<user>/<repo> --branch main --dest /monorepo
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_URL="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --no-open-ports) OPEN_PORTS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$REPO_URL" ]]; then
  echo "--repo is required (e.g., https://github.com/user/repo)" >&2
  usage
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need curl
need tar

echo "==> Preparing destination: $DEST"
sudo mkdir -p "$DEST"
sudo chown "$USER":"$USER" "$DEST"

echo "==> Downloading $REPO_URL (branch: $BRANCH)"
TARBALL_URL="${REPO_URL%/}/archive/refs/heads/${BRANCH}.tar.gz"
TMPDIR="$(mktemp -d)"
curl -fsSL "$TARBALL_URL" -o "$TMPDIR/repo.tar.gz" || { echo "Failed to download tarball from $TARBALL_URL" >&2; exit 1; }

echo "==> Extracting to $DEST"
tar -xzf "$TMPDIR/repo.tar.gz" -C "$TMPDIR"
SUBDIR="$(find "$TMPDIR" -maxdepth 1 -type d -name '*-*' | head -n1)"
if [[ -z "$SUBDIR" ]]; then echo "Extraction failed" >&2; exit 1; fi
shopt -s dotglob
rsync -a "$SUBDIR"/* "$DEST"/

if [[ "$OPEN_PORTS" -eq 1 ]] && command -v ufw >/dev/null 2>&1; then
  if sudo ufw status | grep -q "Status: active"; then
    echo "==> Opening ufw ports 80/443"
    sudo ufw allow 80/tcp || true
    sudo ufw allow 443/tcp || true
  fi
fi

echo "==> Running bootstrap"
cd "$DEST"
bash ./scripts/bootstrap.sh

echo "==> Done. Visit the Admin UI (db.<domain>), API, and Studio URLs after DNS/cert is ready."

