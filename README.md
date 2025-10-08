# Multi Supa — Self-hosted Supabase Multi-project Platform

This monorepo provisions a production-ready setup to run multiple self-hosted Supabase CLI stacks on one VPS, behind a single Caddy reverse proxy with path-based routing, plus an admin API/UI to manage projects and nightly backups to Cloudflare R2.

Key domains (set via `.env`):
- `https://api.<domain>/{project}` → project Kong API
- `https://studio.<domain>/{project}` → Supabase Studio (basic auth)
- `https://db.<domain>` → Admin UI (password)

Contents
- `apps/admin-api` — Fastify + TypeScript API serving admin UI and managing lifecycle
- `apps/admin-ui` — React + Vite UI for login and project management
- `apps/marketing` — Simple marketing site (optional)
- `infrastructure/caddy` — Caddy compose + config (host network)
- `scripts/*.sh` — Bootstrap, create/destroy/list, backup-now
- `templates/` — Caddy include snippets and systemd timer/service
- `state/projects.json` — Authoritative registry of projects

Quick start
1) Point DNS A records for `api.<domain>`, `studio.<domain>`, `db.<domain>` to your VPS IP.
2) Install using ONE of these methods:

   - One-liner (recommended; master branch):

     `curl -fsSL https://raw.githubusercontent.com/silvandiepen/multi-supa/master/scripts/remote-bootstrap.sh | bash -s -- --repo https://github.com/silvandiepen/multi-supa --branch master --dest /monorepo`

   - Tarball (no git required):

     ```bash
     mkdir -p /monorepo && cd /monorepo
     curl -fsSL -o repo.tar.gz https://codeload.github.com/silvandiepen/multi-supa/tar.gz/refs/heads/master
     tar -xzf repo.tar.gz --strip-components=1
     bash ./scripts/bootstrap.sh
     ```

   - Git clone:

     ```bash
     apt-get update && apt-get install -y git
     git clone https://github.com/silvandiepen/multi-supa /monorepo
     cd /monorepo && bash ./scripts/bootstrap.sh
     ```

   The bootstrap is idempotent and will:
   - Ask for domain, admin password (bcrypt), email, Cloudflare R2 settings, optional SMTP
   - Install Docker, Compose plugin, Node LTS, pnpm, awscli, Supabase CLI, jq, zip/unzip
   - Create `/opt/caddy/includes/{api,studio}`, `/srv`, `/var/backups/supabase`
   - Write `.env` at repo root and `/etc/supabase.env`
   - Start Caddy via `docker compose` (host network)
   - Build and start `admin-api` as a systemd service on `127.0.0.1:6010`
   - Create a first project `default`, generate Caddy includes, reload Caddy
   - Install systemd backup templates

3) During bootstrap:
   - A TUI wizard (whiptail) guides you with defaults; you can review and edit fields before confirming. Falls back to plain prompts if TUI unavailable.

4) On completion, visit:
   - Admin UI: `https://db.<domain>` (use the password you set)
   - API: `https://api.<domain>/default`
   - Studio: `https://studio.<domain>/default` (basic auth uses same bcrypt hash; user `admin`)

CLI usage
- Create: `./scripts/create-project.sh <name>`
- Destroy: `./scripts/destroy-project.sh <name> [--purge]`
- List: `./scripts/list-projects.sh` (or `list-projects.sh json`)
- Backup now: `./scripts/backup-now.sh <name|all>`

Admin API routes
- `POST /api/auth/login` { password } → sets cookie
- `GET /api/projects` → list
- `POST /api/projects` { name } → create (calls create script)
- `POST /api/projects/:name/start` → supabase start
- `POST /api/projects/:name/stop` → supabase stop
- `DELETE /api/projects/:name?purge=1` → destroy (calls destroy script)
- `POST /api/projects/:name/backup` → immediate backup
- `GET /api/projects/:name/logs/backup` → backup log
- `GET /api/health` → health check

How routing works
- Caddy runs with `network_mode: host` and terminates TLS for `api.<domain>`, `studio.<domain>`, and `db.<domain>`
- Project path blocks are imported from `/opt/caddy/includes/{api,studio}/*.caddy`
- Each include is generated per project to reverse proxy to `127.0.0.1:{port}`

Port allocation
- For project index `k` (0, 1, 2, …):
  - API/Kong: `54321 + 1000*k`
  - DB: `54322 + 1000*k`
  - Studio: `54323 + 1000*k`
  - Mailpit: `54324 + 1000*k`
- `create-project.sh` scans `ss -ltn` and `/srv/supabase-*` to auto-pick the next free block.

Backups
- Systemd templates at `templates/systemd/backup@.service` and `backup@.timer`.
- Nightly `pg_dump` of each project into `/var/backups/supabase/<name>/<ts>.sql.gz`.
- Uploaded to Cloudflare R2 via `aws s3 cp` (requires `R2_*` in `/etc/supabase.env`).
- Local retention defaults to 14 days (configurable with `BACKUP_LOCAL_RETENTION`).
- Logs: `/var/log/supabase-backup/<name>.log`.

Security
- Admin UI is protected by a password → stored as `ADMIN_BCRYPT_HASH` in `.env`.
- Studio is protected by Caddy `basicauth` using the same bcrypt hash; user is `admin`.
- Admin API binds to `127.0.0.1:6010` and is reverse-proxied via Caddy.
- CORS is not restricted for internal admin routes; Supabase SDK calls go through API path routing.
- No direct Postgres exposure to the internet.

Notes & troubleshooting
- DNS/Certificates: Caddy will request Let’s Encrypt certs when DNS resolves correctly. If DNS has not propagated, cert issuance may fail; wait and re-run `docker compose up -d` in `infrastructure/caddy`.
- Ports colliding: If any of `5432x` ports are in use, `create-project.sh` picks the next block. If mismatch persists, check `ss -ltn`.
- Supabase CLI: Ensure it’s installed (`supabase --version`). If not, rerun `scripts/bootstrap.sh`.
- Caddy reload: Includes are reloaded via `docker compose exec caddy caddy reload`. If it fails, the script will fall back to signaling the container.
- Permissions: Scripts use `sudo` where needed for `/opt`, `/etc`, and `/var`. Run bootstrap as a sudo-capable user.

Optional: Marketing site routing
- You can serve `apps/marketing` under `<domain>` or `www.<domain>` by adding a Caddy block like:

```
# <domain> {
#   root * /monorepo/apps/marketing/dist
#   file_server
# }
```

Build commands
- Top-level: `pnpm -r build` builds all apps
- Dev admin API: `pnpm --filter admin-api dev`
- Dev admin UI: `pnpm --filter admin-ui dev`

Repository structure is designed to be portable and idempotent. Open issues or PRs if you run into rough edges.
