# 🏠 Homelab

A self-hosted, Docker-based homelab running on Debian — structured, automated, and built for easy recovery.

> **Stack:** Docker Compose · Traefik · Tailscale · AdGuard Home · Makefile automation

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [Services](#services)
- [How-To Guides](#how-to-guides)
  - [Add a New Service](#add-a-new-service)
  - [Manage Services with Make](#manage-services-with-make)
  - [Backup and Restore](#backup-and-restore)
  - [Rotate Secrets](#rotate-secrets)
  - [Generate or Renew TLS Certificates](#generate-or-renew-tls-certificates)
  - [Trust the Local CA on a Device](#trust-the-local-ca-on-a-device)
- [Reference](#reference)
  - [Make Targets](#make-targets)
  - [Service Registry](#service-registry)
  - [Networking](#networking)
  - [Secrets and Environment Variables](#secrets-and-environment-variables)
  - [Git Policy](#git-policy)
- [Explanation](#explanation)
  - [Why Traefik over NPM](#why-traefik-over-npm)
  - [The Tailscale Sidecar Pattern](#the-tailscale-sidecar-pattern)
  - [Auto-Discovery and Boot Order](#auto-discovery-and-boot-order)
  - [Why Bind Mounts over Named Volumes](#why-bind-mounts-over-named-volumes)

---

## Overview

This repository contains the complete configuration for a personal homelab. Every service runs in Docker Compose. The repo is structured so that:

- **Configuration is version-controlled.** All `compose.yml` files, scripts, and config templates live here.
- **Secrets are never committed.** A single `shared/.env` file holds all credentials, gitignored by default.
- **Data is recoverable.** Bind mounts make all runtime data visible, inspectable, and easy to back up.
- **Operations are automated.** A single `Makefile` entry point handles starting, stopping, healing, and inspecting all services.

---

## Architecture

```
                        Your Device
                             │
                    Tailscale VPN (WireGuard)
                             │
              ┌──────────────┼──────────────┐
              │              │              │
         ts-traefik       ts-dns         tailscale
         (Traefik)      (AdGuard)       (host VPN)
              │              │
    ┌─────────┴─────┐   DNS rewrites
    │  proxy network │   *.homeserver.com
    │                │   → ts-traefik IP
    │  ┌──────────┐  │
    │  │portainer │  │
    │  │open-webui│  │
    │  │ vscode   │  │
    │  │ ollama   │  │
    │  │copyparty │  │
    │  │  kiwix   │  │
    │  │ adguard  │  │
    │  └──────────┘  │
    └────────────────┘
```

**Traffic flow for `https://portainer.homeserver.com`:**

1. Device sends DNS query → resolved by AdGuard (via Tailscale Split DNS)
2. AdGuard wildcard rewrite returns the Tailscale IP of `ts-traefik`
3. Request reaches Traefik over Tailscale VPN
4. Traefik matches the `Host` rule from the container label → forwards to portainer on the `proxy` Docker network
5. Response returns through Traefik with the wildcard TLS cert

---

## Quick Start

### Prerequisites

- Debian/Ubuntu server with Docker and Docker Compose installed
- `make` and `openssl` available
- A Tailscale account with an auth key

### 1. Clone and configure secrets

```bash
git clone <your-repo-url> ~/homelab
cd ~/homelab
cp shared/.env.example shared/.env
nano shared/.env    # fill in all values
```

### 2. Configure secrets

Fill in your values in `shared/.env`. The management scripts automatically pass this file to every `docker compose` call via `--env-file`, so all `${VAR}` references in any compose file are resolved from a single source — no per-service symlinks needed.

```bash
nano shared/.env
```

> **Note:** Some older services in this repo still have `.env` symlinks from before this was implemented. They are harmless and can be left in place or removed — they are no longer required.

### 3. Generate TLS certificates

```bash
chmod +x scripts/gen-certs.sh scripts/manage.sh scripts/backup.sh scripts/restore.sh scripts/kiwix-pull.sh
./scripts/gen-certs.sh
```

Trust `core/traefik/certs/ca.crt` on each device — see [Trust the Local CA on a Device](#trust-the-local-ca-on-a-device).

### 4. Create the shared Docker network

```bash
make network
```

### 5. Configure AdGuard DNS rewrite

In AdGuard Home → Filters → DNS Rewrites:

| Domain | Target |
|--------|--------|
| `*.homeserver.com` | Tailscale IP of `ts-traefik` |

Get the Traefik Tailscale IP after step 6 from the Tailscale admin dashboard.

### 6. Start everything

```bash
make up
```

---

## Project Structure

```
homelab/
│
├── core/                         # Infrastructure services
│   ├── dns/                      # AdGuard Home + Tailscale sidecar
│   │   ├── compose.yml
│   │   ├── .env -> ../../shared/.env
│   │   ├── config/               # AdGuardHome.yaml (gitignored)
│   │   ├── data/                 # Query logs, filter cache (gitignored)
│   │   └── ts-dns-state/         # Tailscale identity (gitignored)
│   │
│   └── traefik/                  # Traefik reverse proxy + Tailscale sidecar
│   │   ├── compose.yml
│   │   ├── .env -> ../../shared/.env
│   │   ├── config/
│   │   │   ├── traefik.yml       # Static config (entrypoints, providers)
│   │   │   └── dynamic/
│   │   │       └── tls.yml       # Wildcard cert registration
│   │   ├── certs/                # CA + wildcard cert (gitignored)
│   │   └── ts-traefik-state/     # Tailscale identity (gitignored)
│   │
│   ├── vpn/                      # General-purpose Tailscale node (host network)
│   │   ├── compose.yml
│   │   ├── .env -> ../../shared/.env
│   │   └── state/                # Tailscale identity (gitignored)
│   │
│   └── management/
│       ├── portainer/            # Docker management UI
│       │   ├── compose.yml
│       │   └── data/             # Portainer DB, certs (root-owned, gitignored)
│       └── watchtower/           # Automatic image updates
│           └── compose.yml
│
├── services/                     # Personal productivity and AI tools
│   ├── copyparty/                # File manager (replaces Filebrowser)
│   │   ├── compose.yml
│   │   └── config/               # copyparty.conf + hists/ (gitignored)
│   │
│   ├── ollama/                   # Local LLM inference engine
│   │   ├── compose.yml
│   │   └── runtime/              # Model weights — many GBs (gitignored)
│   │
│   ├── open-webui/               # ChatGPT-style UI for Ollama
│   │   ├── compose.yml
│   │   ├── .env -> ../../shared/.env
│   │   └── data/                 # Open WebUI state (gitignored)
│   │
│   └── vscode/                   # Browser-based VS Code
│       ├── compose.yml
│       ├── .env -> ../../shared/.env
│       ├── config/               # Extensions, settings (gitignored)
│       └── projects/             # Your code
│
│   └── kiwix/                        # Offline reference library server
│       ├── compose.yml
│       ├── data/                 # .zim files (gitignored)
│       └── .tmp/                 # In-progress downloads (gitignored)
│
├── apps/                         # Miscellaneous standalone apps
│   └── honeygain/
│       ├── compose.yml
│       └── .env -> ../../shared/.env
│
├── shared/
│   ├── .env                      # Real secrets — GITIGNORED
│   ├── .env.example              # Template — committed to git
│   └── networks.yml              # Reserved for shared network definitions
│
├── scripts/
│   ├── manage.sh                 # Service manager (called by Makefile)
│   ├── services.dep              # Dependency declarations for boot order
│   ├── backup.sh                 # Backup automation
│   ├── restore.sh                # Restore automation
│   ├── gen-certs.sh              # Local CA + wildcard cert generator
│   └── kiwix-pull.sh             # ZIM file downloader for Kiwix
│
├── backups/                      # Backup archives — GITIGNORED
├── Makefile                      # Single entry point for all operations
└── .gitignore
```

---

## Services

| Service | URL | Purpose |
|---------|-----|---------|
| **Traefik** | — | Reverse proxy, automatic HTTPS termination |
| **AdGuard Home** | `https://adguard.homeserver.com` | Network-wide ad blocking, custom DNS rewrites |
| **Portainer** | `https://portainer.homeserver.com` | Docker management UI |
| **Watchtower** | — | Automatic container image updates |
| **Copyparty** | `https://copyparty.homeserver.com` | File manager with WebDAV, resumable uploads |
| **Ollama** | `https://ollama.homeserver.com` | Local LLM inference API |
| **Open WebUI** | `https://ai.homeserver.com` | ChatGPT-style UI backed by Ollama |
| **VS Code** | `https://vscode.homeserver.com` | Browser-based IDE |
| **Kiwix** | `https://kiwix.homeserver.com` | Offline Wikipedia, DevDocs, and reference libraries |
| **Honeygain** | — | Passive income via bandwidth sharing |
| **Tailscale VPN** | — | Host-level VPN node for SSH access |

---

## How-To Guides

### Add a New Service

**Service with no dependencies** (e.g. a simple web app):

```bash
# 1. Create the directory
mkdir -p ~/homelab/services/myapp

# 2. Write the compose file
cat > ~/homelab/services/myapp/compose.yml << 'EOF'
services:
  myapp:
    image: someimage:latest
    container_name: myapp
    restart: unless-stopped
    networks:
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.homeserver.com`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls=true"
      - "traefik.http.services.myapp.loadbalancer.server.port=8080"
      - "traefik.docker.network=proxy"

networks:
  proxy:
    external: true
    name: proxy
EOF

# 3. Start it — auto-discovered immediately, no config changes needed
make myapp
```

**Service that depends on another** (e.g. an app that needs a database):

```bash
# After creating the compose file, add one line to services.dep:
echo "myapp -> mydb" >> ~/homelab/scripts/services.dep
```

**Service that needs secrets:**

Reference them directly in `environment:` using `${VAR}` syntax, then add the variable to `shared/.env`:

```yaml
services:
  myapp:
    environment:
      - API_KEY=${MYAPP_API_KEY}
      - PASSWORD=${MYAPP_PASSWORD}
```

```bash
echo "MYAPP_API_KEY=abc123" >> ~/homelab/shared/.env
```

No symlink, no `env_file:` needed — `manage.sh` handles it automatically.

**Add to `.gitignore`** if the service creates runtime data:

```
services/myapp/data/
services/myapp/config/
```

**Add to `backup.sh`** if data needs to be backed up:

```bash
# In the SERVICES map inside scripts/backup.sh:
[myapp]="services/myapp/compose.yml|services/myapp/data services/myapp/config"
```

---

### Remove a Service

**Remove containers but keep files** — useful when you want to stop a service temporarily or reconfigure it before bringing it back:

```bash
make reverse-proxy-remove
# Prompts: "Type yes to continue"
# Result: containers gone, compose/config/data all intact on disk
```

**Delete a service entirely** — removes containers and the entire service directory from disk. Irreversible:

```bash
make reverse-proxy-delete
# Prompts: "Type the service name to confirm: reverse-proxy"
# Result: containers gone, directory deleted, services.dep entry cleaned up
```

The delete command also automatically removes the service's entry from `scripts/services.dep` if one exists, keeping the dependency graph clean. Auto-discovery won't find the service on the next run since there's no `compose.yml` left.

> **Tip:** Run `make backup` before deleting anything with data you might want to recover.

---

### Manage Services with Make

```bash
# ── Global ────────────────────────────────────────────────────────────
make up                  # Start all services in correct boot order
make down                # Stop all services (prompts for confirmation)
make status              # Health table for all services
make heal                # Start any crashed or missing services
make list                # List all services with deps and boot order
make network             # Create the shared proxy Docker network

# ── Per service ───────────────────────────────────────────────────────
make ollama              # Start ollama (starts deps first automatically)
make ollama-down         # Stop ollama
make ollama-restart      # Recreate container — fully applies compose changes
make ollama-logs         # Follow logs (Ctrl+C to exit)
make ollama-pull         # Pull latest image (does not restart)
make ollama-remove       # Stop and remove containers, keep files on disk
make ollama-delete       # Remove containers AND delete the service directory

# ── Dependency resolution ─────────────────────────────────────────────
make open-webui          # Starts ollama first (dep), then open-webui
make dns                 # Starts vpn first (dep), then dns
```

> **Reverse-proxy awareness:** Some services need to be told they are behind a proxy or they will reject forwarded requests. Copyparty, for example, requires `--rproxy -1 --xff-src lan` in its `command:` block. Check your service's documentation for equivalent settings if you see CORS or IP-forwarding errors in its logs.

> **Note:** `make <service>-restart` uses `--force-recreate` — it fully applies any compose file changes. Always use this after editing a compose file, never plain `docker compose restart`.

---

### Manage Kiwix

Kiwix serves offline `.zim` files — self-contained archives of websites like Wikipedia, DevDocs, and Stack Overflow. Use `kiwix-pull.sh` to download and manage them.

```bash
# See all available categories
make kiwix-list

# Browse files in a category (shows all files, all dates)
make kiwix-pull ARGS="--browse devdocs"

# Browse filtered by language
make kiwix-pull ARGS="--browse wikipedia --lang fr"

# Preview what would be downloaded (latest English per series)
make kiwix-pull ARGS="--dry-run devdocs"

# Download latest English files in a category
make kiwix-pull ARGS="devdocs"

# Download in a specific language
make kiwix-pull ARGS="--lang de wikipedia"

# Download all languages
make kiwix-pull ARGS="--all-lang freecodecamp"

# Download one exact file by name
make kiwix-pull ARGS="--file wikipedia_en_all_2026-02.zim wikipedia"

# Download one exact file by full URL (paste directly from browser)
make kiwix-pull ARGS="--file https://download.kiwix.org/zim/other/archlinux_en_all_maxi_2025-09.zim"

# Multiple categories at once
make kiwix-pull ARGS="devdocs freecodecamp stack_exchange"
```

**Resume support:** Downloads use a `.tmp` staging file. If interrupted with Ctrl+C, the partial file is kept and the next run resumes from where it left off. On completion the file is atomically moved to `data/` so Kiwix never sees a partial archive.

**Auto-cleanup of old versions:** When a newer version of a file is downloaded, the previous version is automatically removed.

After adding new `.zim` files, restart Kiwix to load them:

```bash
make kiwix-restart
```

---

### Backup and Restore

```bash
# Full backup of all services
./scripts/backup.sh

# Backup a single service
./scripts/backup.sh ollama
./scripts/backup.sh portainer

# Skip stopping containers (faster, slight risk of partial writes)
./scripts/backup.sh --no-stop

# List available backups
./scripts/restore.sh --list

# Full restore from a backup
./scripts/restore.sh backups/2026-03-03_15-30-58.tar.gz

# Restore a single service only
./scripts/restore.sh backups/2026-03-03_15-30-58.tar.gz ollama
```

**Automate with cron** — full backup every night at 2am:

```bash
crontab -e
# Add:
0 2 * * * /home/meshwa/homelab/scripts/backup.sh --no-stop >> /home/meshwa/homelab/backups/cron.log 2>&1
```

The backup script keeps the last 7 archives and deletes older ones automatically.

---

### Rotate Secrets

**Tailscale auth key:**

```bash
# Update the key in shared/.env
nano ~/homelab/shared/.env   # edit TS_AUTHKEY

# Wipe state and re-register all Tailscale nodes
sudo rm -rf core/dns/ts-dns-state/*
sudo rm -rf core/traefik/ts-traefik-state/*
sudo rm -rf core/vpn/state/*

make dns-restart
make traefik-restart
make vpn-restart
```

**Any other secret** (passwords, API keys):

```bash
nano ~/homelab/shared/.env
# Restart the affected service to pick up the change:
make <service>-restart
```

---

### Generate or Renew TLS Certificates

The wildcard cert is valid for ~2 years. Regenerate it before it expires:

```bash
./scripts/gen-certs.sh
make traefik-restart
```

Check expiry at any time:

```bash
openssl x509 -in core/traefik/certs/wildcard.crt -noout -dates
```

---

### Trust the Local CA on a Device

The CA certificate is at `core/traefik/certs/ca.crt`. Install it once per device — all `*.homeserver.com` subdomains will then show as trusted.

**Linux:**
```bash
sudo cp core/traefik/certs/ca.crt /usr/local/share/ca-certificates/homeserver-ca.crt
sudo update-ca-certificates
```

**macOS:**
```bash
open core/traefik/certs/ca.crt
# → Keychain Access → double click cert → Trust → Always Trust
```

**Windows:**
Double-click `ca.crt` → Install Certificate → Local Machine → Trusted Root Certification Authorities

**iOS:**
AirDrop `ca.crt` to device → Settings → Profile Downloaded → Install → Settings → General → About → Certificate Trust Settings → Enable full trust

**Android:**
Settings → Security → Install certificate → CA certificate → select `ca.crt`

---

## Reference

### Make Targets

| Target | Description |
|--------|-------------|
| `make up` | Start all services in boot order |
| `make down` | Stop all services (confirmation required) |
| `make status` | Health table: running / partial / exited / missing |
| `make heal` | Start any stopped or missing services |
| `make list` | All services with compose path and dependencies |
| `make network` | Create the shared `proxy` Docker network |
| `make help` | Full usage reference |
| `make <svc>` | Start a service (resolves deps automatically) |
| `make <svc>-down` | Stop a service |
| `make <svc>-restart` | Recreate container — fully applies compose changes |
| `make <svc>-logs` | Follow logs |
| `make <svc>-pull` | Pull latest image without restarting |
| `make <svc>-remove` | Stop and remove containers, keep files on disk |
| `make <svc>-delete` | Remove containers and delete the entire service directory |
| `make kiwix-list` | List all available ZIM categories on the Kiwix server |
| `make kiwix-pull ARGS="..."` | Download ZIM files (see Manage Kiwix below) |

---

### Service Registry

Services are **auto-discovered** at runtime — the scripts scan for all `compose.yml` files under `homelab/`. You never register a new service manually.

Dependencies are declared in `scripts/services.dep`:

```
# Format: service -> dep1 dep2
dns        -> vpn
traefik    -> vpn
open-webui -> ollama
```

Boot order is derived automatically via topological sort (Kahn's algorithm). Services with no dependencies run alphabetically. Circular dependencies are detected and reported before anything starts.

---

### Networking

| Network | Type | Purpose |
|---------|------|---------|
| `proxy` | External Docker bridge | Shared network between Traefik and all proxied services |
| Tailscale VPN | WireGuard overlay | Secure remote access to all sidecar nodes |
| Host network | `network_mode: host` | Used by `tailscale` (VPN) for direct host access |
| Sidecar namespace | `network_mode: service:ts-*` | Used by Traefik and AdGuard to share their Tailscale node's IP |

**The `proxy` network must exist before starting any service.** Create it with `make network`. It is created automatically when running `make up`.

**All containers use external DNS.** The host `/etc/docker/daemon.json` is configured with `8.8.8.8` and `1.1.1.1` as default resolvers so containers can reach the internet regardless of which Docker network they are on. This is required because the host's `/etc/resolv.conf` points to AdGuard via Tailscale, which is unreachable from inside Docker networks.

```json
{
  "dns": ["8.8.8.8", "1.1.1.1"]
}
```

---

### Secrets and Environment Variables

All secrets live in one file: `shared/.env`. This file is gitignored and never committed.

```
shared/
├── .env           ← real secrets (gitignored)
└── .env.example   ← template with placeholder values (committed)
```

The `manage.sh` script passes `--env-file shared/.env` to every `docker compose` invocation. This means any `${VAR}` in any compose file is automatically resolved from `shared/.env` — no symlinks, no `env_file:` directives needed.

**Adding secrets to a new service:**

```yaml
# In your compose.yml — reference vars directly, no env_file needed
services:
  myapp:
    environment:
      - MY_API_KEY=${MY_API_KEY}
      - MY_PASSWORD=${MY_PASSWORD}
```

```bash
# Add the vars to shared/.env
echo "MY_API_KEY=abc123" >> shared/.env
echo "MY_PASSWORD=hunter2" >> shared/.env
```

That's it. No symlink, no `env_file:` block.

> **Legacy symlinks:** Some services have `.env -> ../../shared/.env` symlinks from before `--env-file` was implemented. These are harmless but redundant — `**/.env` in `.gitignore` ensures they are never committed.

**Required variables:**

| Variable | Used by | Description |
|----------|---------|-------------|
| `TS_AUTHKEY` | All Tailscale sidecars | Tailscale auth key |
| `TS_HOSTNAME_VPN` | `core/vpn` | Hostname shown in Tailscale dashboard |
| `TS_HOSTNAME_DNS` | `core/dns` | Hostname for AdGuard sidecar |
| `TS_HOSTNAME_TRAEFIK` | `core/traefik` | Hostname for Traefik sidecar |
| `HONEYGAIN_EMAIL` | `apps/honeygain` | Honeygain account email |
| `HONEYGAIN_PASS` | `apps/honeygain` | Honeygain account password |
| `HONEYGAIN_DEVICE` | `apps/honeygain` | Device name in Honeygain dashboard |
| `OLLAMA_BASE_URL` | `services/open-webui` | Set to `http://ollama:11434` — resolved via Docker container DNS on the shared `proxy` network |

---

### Git Policy

**Committed:**
- All `compose.yml` files
- `shared/.env.example`
- `scripts/` directory
- `Makefile`, `.gitignore`, `README.md`
- `core/traefik/config/` (static and dynamic Traefik config)

**Gitignored:**
- `shared/.env` — real secrets
- All `data/`, `config/`, `state/`, `runtime/` directories — runtime data
- All `*-state/` directories — Tailscale private keys
- `core/traefik/certs/` — private keys and certificates
- `services/ollama/runtime/` — model weights
- `services/kiwix/data/` — ZIM files (large, not version-controlled)
- `services/kiwix/.tmp/` — in-progress downloads
- `backups/*.tar.gz` — backup archives

**Before every commit:**

```bash
# Verify no secrets or state are staged
git diff --cached --name-only | grep -E "\.env|state|\.pem|\.key|\.db"
# Must return nothing
```

---

## Explanation

### Why Traefik over NPM

Nginx Proxy Manager is a GUI wrapper around nginx — it was designed for humans to click through. Every new service requires manually navigating the UI to add a proxy host.

Traefik is designed for automation. It watches the Docker socket and reads labels directly from your containers. Adding a new service means adding five lines to a `compose.yml` — Traefik discovers it instantly without a restart and without touching any central configuration.

This is the standard pattern in production environments and orchestration platforms like Kubernetes (where it's called an Ingress Controller).

---

### The Tailscale Sidecar Pattern

Normally, making a service accessible on Tailscale would mean binding it to the host's Tailscale interface. This has two problems: it exposes the service on the same IP as everything else, and it mixes infrastructure concerns.

The sidecar pattern solves this cleanly. A dedicated Tailscale container (`ts-traefik`, `ts-dns`) connects to Tailscale and gets its own stable VPN IP. The actual service container (`traefik`, `adguard`) sets `network_mode: service:ts-*` to share that container's network namespace entirely. The result: the service is accessible only via the Tailscale IP of its sidecar, completely isolated from the LAN.

```
Internet → Tailscale VPN → ts-traefik (Tailscale node, IP: 100.x.x.x)
                                 ↕ (shared network namespace)
                           traefik (reverse proxy, port 443)
```

If you remove the sidecar, the service becomes completely unreachable. No firewall rules needed.

---

### Auto-Discovery and Boot Order

The `manage.sh` script finds all services by scanning for `compose.yml` files using `find`. The service name is the directory name containing the file. This means:

- Adding a service requires no registration step
- Renaming a directory changes the service name automatically
- Duplicate directory names across different paths will error loudly

Boot order is not hardcoded. `scripts/services.dep` declares only the edges of the dependency graph (which service needs which). The script runs a topological sort (Kahn's algorithm) over the full graph to produce a valid start order. Services with no dependencies are sorted alphabetically among themselves. If the graph contains a cycle (e.g. A depends on B and B depends on A), the sort detects this and exits with a clear error listing the offending services before anything starts.

---

### Why Bind Mounts over Named Volumes

Docker named volumes are managed by Docker's internal storage engine. They are opaque — you cannot easily inspect, copy, or back them up without running a helper container.

Bind mounts map a host directory directly into the container. Every piece of runtime data is a visible directory on disk:

```
services/ollama/runtime/   ← model weights, visible and inspectable
core/dns/config/           ← AdGuard config, editable with any text editor
```

This makes backup trivial (`cp -r` or `tar`), migration straightforward (copy the directory to a new host), and debugging easy (inspect files without entering the container). The tradeoff is that you must manage directory ownership manually — the scripts handle this for root-owned paths like Portainer.

The one exception is `open-webui-data`, which uses a named volume because Open WebUI's image writes to a path that cannot easily be remapped with a bind mount. The backup script handles this with a temporary Alpine container.
