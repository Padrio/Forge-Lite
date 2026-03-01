# forge-lite

A lightweight, bash-based server provisioning and deployment system for Laravel projects. A self-hosted alternative to Laravel Forge, targeting Ubuntu 24.04.

## Features

- **Full server provisioning**: NGINX, PHP 8.1–8.4, MariaDB, Redis, Node.js, Supervisor, Certbot
- **Site management**: One command to create a fully configured Laravel site (FPM pool, vhost, database, queue workers, scheduler, SSL)
- **Zero-downtime deployments**: Atomic symlink swap with automatic rollback support
- **CI/CD ready**: GitHub Actions workflows for automatic deployment on push
- **Idempotent**: Every script is safe to re-run
- **CLI tools**: `php-switch`, `forge-lite-db`, `forge-lite-ssl`

## Prerequisites

- Fresh Ubuntu 24.04 server
- Root access (or sudo)
- SSH key-based access configured

## Quick Start

### Cloud-init (fully automated)

Provision a fresh server without logging in — paste `cloud-init/cloud-config.yml` as **User Data** when creating the server. Edit the configuration variables at the top of the `runcmd` block (repo URL, PHP version, passwords, etc.) before use.

Works with Hetzner Cloud, DigitalOcean, AWS EC2, Vultr, Linode, and any provider that supports cloud-init.

Monitor progress on the server:
```bash
tail -f /var/log/forge-lite-cloud-init.log
```

### 1. Clone to the server

```bash
git clone https://github.com/Padrio/Forge-Lite.git /opt/forge-lite
cd /opt/forge-lite
```

### 2. Provision the server

```bash
sudo bash server/provision.sh
```

Options:
```
--php-default=8.3       Default PHP CLI version
--db-password=PASS      MariaDB root password (auto-generated if omitted)
--redis-password=PASS   Redis password (auto-generated if omitted)
--node-version=22       Node.js major version
--skip-reboot           Don't reboot after provisioning
--force                 Re-provision (ignores existing marker)
```

### 3. Add a site

```bash
sudo bash sites/add-site.sh \
  --domain=example.com \
  --php=8.3 \
  --queue-workers=2 \
  --ssl
```

Options:
```
--domain=DOMAIN         Domain name (required)
--php=VERSION           PHP version (default: 8.3)
--queue-workers=N       Queue worker processes (default: 2)
--enable-ssr            Enable Inertia SSR process
--enable-horizon        Use Horizon instead of queue workers
--no-scheduler          Disable Laravel scheduler
--ssl                   Issue SSL certificate
```

### 4. Deploy

**Manual deployment (on the server):**
```bash
sudo bash deploy/deploy.sh example.com \
  --repo=git@github.com:your-org/your-app.git \
  --branch=main
```

**Artifact deployment (from CI):**
```bash
sudo bash deploy/deploy.sh example.com \
  --artifact=/tmp/deploy-artifact.tar.gz
```

**Rollback:**
```bash
sudo bash deploy/rollback.sh example.com
```

### 5. GitHub Actions (CI/CD)

1. Edit `.github/workflows/deploy-production.yml` — set your domain
2. Edit `.github/workflows/deploy-staging.yml` — set your staging domain
3. Add repository secrets:
   - `SSH_PRIVATE_KEY` — Private SSH key for the deployer user
   - `SSH_HOST` — Server IP or hostname
   - `SSH_USER` — SSH username (e.g., `deployer`)
4. Push to `main` (production) or `develop` (staging) to trigger deployment

## CLI Tools

After provisioning, these are installed to `/usr/local/bin/`:

### php-switch
```bash
sudo php-switch 8.4      # Switch default PHP CLI + FPM
```

### forge-lite-db
```bash
sudo forge-lite-db create myapp       # Create database + user
sudo forge-lite-db list               # List databases
sudo forge-lite-db backup myapp       # Backup to /home/deployer/backups/
sudo forge-lite-db restore myapp dump.sql.gz
sudo forge-lite-db drop myapp --yes   # Drop database + user
```

### forge-lite-ssl
```bash
sudo forge-lite-ssl issue example.com    # Obtain certificate
sudo forge-lite-ssl renew example.com    # Force renew
sudo forge-lite-ssl status example.com   # Show certificate info
```

## Site Removal

```bash
sudo bash sites/remove-site.sh example.com
sudo bash sites/remove-site.sh example.com --keep-db --keep-files
```

## Directory Layout

### On the server
```
/home/deployer/sites/<domain>/
├── releases/                  # Timestamped release directories
│   ├── 20240101_120000/
│   └── 20240102_150000/
├── shared/
│   ├── .env                   # Shared environment file
│   └── storage/               # Shared Laravel storage
└── current -> releases/XXX    # Symlink to active release
```

### Configuration
```
/etc/forge-lite/<domain>.conf     # Site configuration (KEY=VALUE)
/root/.forge-lite-credentials     # Generated passwords (chmod 600)
```

## What Gets Provisioned

| Component | Details |
|-----------|---------|
| **System** | deployer user, UTC timezone, en_US.UTF-8 locale, open file limits |
| **Swap** | Size based on RAM, sysctl tuning, OOM priorities |
| **Security** | SSH hardening, UFW (22/80/443), Fail2Ban, unattended-upgrades |
| **NGINX** | Mainline, DH params, gzip, rate limiting, security headers |
| **PHP** | 8.1, 8.2, 8.3, 8.4 with FPM + Laravel extensions + OPcache/JIT |
| **Composer** | Global install with weekly auto-update |
| **MariaDB** | Secured, InnoDB tuned (70% RAM), forge-lite admin user |
| **Redis** | Password-protected, AOF, maxmemory (25% RAM), allkeys-lru |
| **Node.js** | v22 via NodeSource |
| **Supervisor** | For queue workers, Horizon, SSR |
| **Certbot** | Let's Encrypt with nginx plugin + auto-renewal |

## Troubleshooting

**View credentials:**
```bash
sudo cat /root/.forge-lite-credentials
```

**Check site config:**
```bash
cat /etc/forge-lite/example.com.conf
```

**Test NGINX config:**
```bash
sudo nginx -t
```

**View FPM status:**
```bash
sudo systemctl status php8.3-fpm
```

**View queue worker logs:**
```bash
tail -f /home/deployer/sites/example.com/shared/storage/logs/worker.log
```

**Re-provision (safe — idempotent):**
```bash
sudo bash /opt/forge-lite/server/provision.sh --force --skip-reboot
```

## License

MIT
