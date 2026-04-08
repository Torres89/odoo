# Odoo 19.0 EC2 Production Deployment Guide

This document outlines the complete step-by-step process for deploying Odoo 19.0 to an AWS EC2 instance with automatic HTTPS via Caddy, and continuous deployment via GitHub Actions.

**Domain:** `automationhr-ai.com`
**Subdomain:** `erp-odoo.automationhr-ai.com`

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Phase 1: AWS Console Infrastructure Setup](#phase-1-aws-console-infrastructure-setup)
3. [Phase 2: DNS Configuration (Route 53)](#phase-2-dns-configuration-route-53)
4. [Phase 3: Server Software Installation](#phase-3-server-software-installation)
5. [Phase 4: Project Configuration Files](#phase-4-project-configuration-files)
6. [Phase 5: GitHub Actions CI/CD Pipeline](#phase-5-github-actions-cicd-pipeline)
7. [Phase 6: First Deployment (Manual)](#phase-6-first-deployment-manual)
8. [Phase 7: Verify Deployment](#phase-7-verify-deployment)
9. [Ongoing Operations](#ongoing-operations)
10. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
                        Internet
                           |
                     [Route 53 DNS]
                erp-odoo.automationhr-ai.com
                           |
                     [EC2 Instance]
                           |
                  ┌────────┴────────┐
                  │   Caddy (443)   │  ← Automatic HTTPS via Let's Encrypt
                  └────────┬────────┘
                           |
              ┌────────────┼────────────┐
              │            │            │
        Odoo Web (8069)  Longpoll    Static
              │          (8072)      Assets
              │            │
        ┌─────┴─────┐     │
        │ PostgreSQL │     │
        │   (5432)   │     │
        └────────────┘     │
              │            │
         [pg-data]   [odoo-filestore]
          volume        volume
```

**Services:**
- **Caddy** — Reverse proxy with automatic HTTPS (Let's Encrypt)
- **Odoo** — The ERP application (port 8069 + 8072 for longpolling)
- **PostgreSQL 16** — Database

**CI/CD Flow:**
```
Push to 19.0 branch → GitHub Actions builds Docker image → Pushes to GHCR → SSHs to EC2 → Pulls new image → Restarts containers
```

---

## Phase 1: AWS Console Infrastructure Setup

### Step 1: Launch the EC2 Instance

1. Go to the **EC2 Dashboard** → click **Launch Instance**.
2. Configure:

   | Setting | Value |
   |---------|-------|
   | **Name** | `odoo-erp-prod` |
   | **OS Image (AMI)** | Ubuntu Server 24.04 LTS |
   | **Instance Type** | `t3.medium` (2 vCPU, 4 GiB RAM) — minimum for Odoo with workers |
   | **Key Pair** | Create new → `odoo-prod-key.pem` → **Download and save securely** |
   | **Storage** | 30 GB gp3 (root volume) |

3. **Network Settings** — Create a new Security Group with these rules:

   | Type | Port | Source | Purpose |
   |------|------|--------|---------|
   | SSH | 22 | My IP | Remote access |
   | HTTP | 80 | 0.0.0.0/0 | Caddy HTTP (redirects to HTTPS) |
   | HTTPS | 443 | 0.0.0.0/0 | Caddy HTTPS |

   > **Important:** Do NOT expose ports 8069, 8072, or 5432 to the internet. Only Caddy (80/443) should be public. Odoo and PostgreSQL communicate internally via Docker networking.

4. Click **Launch Instance**.

### Step 2: Assign a Static IP (Elastic IP)

Without an Elastic IP, your instance gets a new public IP every time it restarts — breaking your DNS.

1. EC2 Dashboard → left menu → **Network & Security** → **Elastic IPs**.
2. Click **Allocate Elastic IP address** → **Allocate**.
3. Select the new IP → **Actions** → **Associate Elastic IP address**.
4. Choose the `odoo-erp-prod` instance → **Associate**.
5. **Copy this IP address** — you need it for DNS in the next phase.

---

## Phase 2: DNS Configuration (Route 53)

### Step 1: Create the Subdomain A Record

1. Go to **Route 53 Dashboard** → **Hosted zones** → click on `automationhr-ai.com`.
2. Click **Create record**:

   | Field | Value |
   |-------|-------|
   | **Record name** | `erp-odoo` |
   | **Record type** | `A` |
   | **Value** | `<Your Elastic IP>` (e.g., `12.34.56.78`) |
   | **TTL** | `300` |

3. Click **Create records**.

### Step 2: Verify DNS Propagation

Wait a few minutes, then verify from your local machine:

```bash
nslookup erp-odoo.automationhr-ai.com
```

or

```bash
ping erp-odoo.automationhr-ai.com
```

The response should show your Elastic IP. DNS propagation usually takes 1-5 minutes with a 300s TTL.

---

## Phase 3: Server Software Installation

### Step 1: SSH into the Server

From your local machine (Windows):

```bash
ssh -i "<path-to-your-key.pem>" ubuntu@<Your-Elastic-IP>
```

> **Tip:** If the connection closes immediately, run with `-v` flag for verbose output to diagnose:
> ```bash
> ssh -v -i "<path-to-your-key.pem>" ubuntu@<Your-Elastic-IP>
> ```

### Step 2: System Update and Security

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y fail2ban unattended-upgrades
```

- **fail2ban** — Blocks IPs after repeated failed SSH login attempts.
- **unattended-upgrades** — Automatically installs security patches.

### Step 3: Install Docker and Docker Compose

```bash
# Download and run the official Docker install script
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Allow the ubuntu user to run Docker without sudo
sudo usermod -aG docker ubuntu

# IMPORTANT: Log out and back in for group membership to take effect
exit
```

SSH back in, then verify:

```bash
docker --version
docker compose version
docker ps   # Should work without sudo
```

### Step 4: Create the Application Directory

```bash
mkdir ~/odoo-erp
cd ~/odoo-erp
```

---

## Phase 4: Project Configuration Files

You need to create/upload the following files in your Odoo project repository. These are the files that live in your project and get deployed.

### File 1: `Caddyfile` (Reverse Proxy)

Create this file in the root of your Odoo repository (`<project-root>\Caddyfile`):

```caddyfile
erp-odoo.automationhr-ai.com {
    # Longpolling / websocket endpoint
    handle /websocket {
        reverse_proxy odoo:8072
    }

    handle /longpolling/* {
        reverse_proxy odoo:8072
    }

    # All other traffic goes to the main Odoo process
    handle {
        reverse_proxy odoo:8069 {
            header_up X-Forwarded-Proto {scheme}
            header_up X-Forwarded-For {remote_host}
            header_up X-Real-IP {remote_host}
        }
    }

    # File upload size limit (Odoo handles large imports/attachments)
    request_body {
        max_size 200MB
    }

    # Enable gzip compression
    encode gzip

    # Logging
    log {
        output stdout
        format console
    }
}
```

> **How Caddy HTTPS works:** Caddy automatically obtains and renews Let's Encrypt TLS certificates. No manual SSL configuration needed. It listens on ports 80 (for ACME challenges and HTTP→HTTPS redirects) and 443 (HTTPS). This is why the Security Group must allow both ports.

### File 2: `docker-compose.prod.yml` (Production Overrides)

Create this file in the root of your repository (`<project-root>\docker-compose.prod.yml`):

```yaml
services:
  odoo:
    image: ghcr.io/${GH_USER_OR_ORG}/odoo-erp:latest
    build: !reset null
    ports: !reset
      - "127.0.0.1:8069:8069"
      - "127.0.0.1:8072:8072"
    environment:
      HOST: db
      USER: odoo
      PASSWORD: ${POSTGRES_PASSWORD}

  db:
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    depends_on:
      - odoo

volumes:
  caddy-data:
  caddy-config:
```

> **What this does:**
> - Overrides the `odoo` service to use the pre-built image from GHCR instead of building locally.
> - Binds Odoo ports to `127.0.0.1` only — not accessible from the internet, only via Caddy.
> - Adds the Caddy reverse proxy container.
> - Uses environment variables from `.env` for secrets.

### File 3: `docker/odoo.conf` (Already Exists — Verify)

Your existing `docker/odoo.conf` already has `proxy_mode = True` which is required for running behind Caddy. The `admin_passwd` (master password for database management) is **not** in this file — it is passed securely via the `ADMIN_PASSWD` environment variable in `.env.prod` (see File 4 below), keeping it out of git.

```ini
[options]
addons_path = /opt/odoo/addons,/opt/odoo/odoo/addons,/mnt/extra-addons,/mnt/extra-addons/odoo-llm
data_dir = /var/lib/odoo
db_host = db
db_port = 5432
db_user = odoo
db_password = odoo
db_maxconn = 64
proxy_mode = True
workers = 4
max_cron_threads = 2
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_time_cpu = 600
limit_time_real = 1200
```

> **Important:** `proxy_mode = True` is critical. Without it, Odoo ignores the `X-Forwarded-*` headers from Caddy and generates incorrect URLs (http instead of https).
>
> **Note:** `admin_passwd` is passed via `docker-compose.yml` using the `--admin_passwd` CLI flag, sourced from the `ADMIN_PASSWD` variable in `.env`. This keeps the master password out of version control.

### File 4: `.env.prod` (Environment Secrets — NOT committed to git)

Create this file locally (do NOT commit it). It will be uploaded to the server via `scp`.

Create `<project-root>\.env.prod`:

```env
GH_USER_OR_ORG=<your-github-username-lowercase>
POSTGRES_PASSWORD=<a_strong_database_password>
ADMIN_PASSWD=<a_strong_admin_master_password>
```

> **Note:**
> - `GH_USER_OR_ORG` must be **lowercase** (GHCR/Docker requirement).
> - `POSTGRES_PASSWORD` is used by both PostgreSQL and Odoo to connect to the database.
> - `ADMIN_PASSWD` is the Odoo master password for the database management page (`/web/database/manager`). It is passed to Odoo via the `--admin_passwd` CLI flag in `docker-compose.yml`.

Make sure `.env.prod` is in your `.gitignore`:

```gitignore
.env.prod
.env
```

### File 5: Upload Config Files to Server

From your local machine, transfer the production files to the EC2 instance:

**PowerShell (Windows):**

```powershell
# Navigate to your Odoo project directory
cd "C:\Users\alfre\Documents\odoo"

# Set your key path and server IP
$KEY = "<project-root>\keypair\odoo-prod-key.pem"
$SERVER = "ubuntu@<Your-Elastic-IP>"

# Upload docker-compose files and Caddyfile
scp -i $KEY docker-compose.yml ${SERVER}:~/odoo-erp/
scp -i $KEY docker-compose.prod.yml ${SERVER}:~/odoo-erp/
scp -i $KEY Caddyfile ${SERVER}:~/odoo-erp/

# Upload the environment file (rename to .env on the server)
scp -i $KEY .env.prod ${SERVER}:~/odoo-erp/.env
```

Then SSH in and verify:

```powershell
ssh -i $KEY $SERVER
cd ~/odoo-erp
ls -la
cat .env   # Verify contents look correct
```

> **Note:** PowerShell uses `$` for variables and `$HOST` is a reserved name in PowerShell — use `$SERVER` instead.

---

## Phase 5: GitHub Actions CI/CD Pipeline

### Step 1: Create the Workflow File

Create `.github/workflows/deploy.yml` in your repository:

```yaml
name: Deploy Odoo to EC2

on:
  push:
    branches:
      - "19.0"
  workflow_dispatch:

env:
  REGISTRY: ghcr.io

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Set image name (lowercase required by Docker/GHCR)
        id: image
        run: echo "name=ghcr.io/$(echo '${{ github.repository_owner }}' | tr '[:upper:]' '[:lower:]')/odoo-erp" >> $GITHUB_OUTPUT

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push Odoo image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ steps.image.outputs.name }}:latest
            ${{ steps.image.outputs.name }}:${{ github.sha }}

  deploy:
    needs: build-and-push
    runs-on: ubuntu-latest
    steps:
      - name: Deploy to EC2 via SSH
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_KEY }}
          script: |
            cd ~/odoo-erp

            # GH_USER_OR_ORG must be lowercase (Docker/GHCR requirement)
            export GH_USER_OR_ORG=$(echo '${{ github.repository_owner }}' | tr '[:upper:]' '[:lower:]')

            # Login to GHCR (needed for private repos)
            if [ -n "${{ secrets.GHCR_PAT }}" ]; then
              echo "${{ secrets.GHCR_PAT }}" | docker login ghcr.io -u ${{ github.repository_owner }} --password-stdin
            fi

            # Pull latest image and restart
            docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
            docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

            # Clean up old images to save disk space
            docker image prune -f
```

### Step 2: Configure GitHub Repository Secrets

Go to your GitHub repository → **Settings** → **Secrets and variables** → **Actions** → **Secrets** tab.

Create these secrets:

---

**Secret 1: `EC2_HOST`**

| Field | Value |
|-------|-------|
| **Name** | `EC2_HOST` |
| **Value** | Your Elastic IP address (e.g., `12.34.56.78`) |

---

**Secret 2: `EC2_SSH_KEY`**

| Field | Value |
|-------|-------|
| **Name** | `EC2_SSH_KEY` |
| **Value** | The entire contents of `odoo-prod-key.pem` |

Open the `.pem` file in a text editor, copy everything from `-----BEGIN ... KEY-----` to `-----END ... KEY-----` inclusive. Paste the whole block. Do not add or remove any characters.

---

**Secret 3: `GHCR_PAT`** *(only if your repository is private)*

| Field | Value |
|-------|-------|
| **Name** | `GHCR_PAT` |
| **Value** | A GitHub Personal Access Token with `read:packages` scope |

**To create the PAT:**
1. GitHub → your **profile picture** → **Settings** → **Developer settings** → **Personal access tokens** → **Tokens (classic)**.
2. **Generate new token (classic)** → name it `EC2 Deploy` → select `read:packages` → **Generate**.
3. Copy the token and paste it as the secret value. Store it somewhere safe.

---

**Summary:** After this, you should see `EC2_HOST`, `EC2_SSH_KEY`, and (if private repo) `GHCR_PAT` in your repository secrets list.

---

## Phase 6: First Deployment

### Step 0: Push to GitHub (Trigger the CI/CD Build)

Before the server can pull any image, you must push your code to the `19.0` branch so GitHub Actions builds and uploads the Docker image to GHCR.

```bash
git add .
git commit -m "[ADD] deploy: add Docker deployment configuration and project files"
git push origin 19.0
```

Then go to your GitHub repo → **Actions** tab and verify the workflow runs successfully. Wait for the `build-and-push` job to complete. The `deploy` job may fail the first time if you haven't uploaded config files to the server yet — that's OK, you just need the image built and pushed to GHCR.

### Step 1: Upload Config Files to Server

Follow [Phase 4, File 5](#file-5-upload-config-files-to-server) to upload `docker-compose.yml`, `docker-compose.prod.yml`, `Caddyfile`, and `.env.prod` to the server.

### Step 2: SSH into the Server

```powershell
ssh -i "<path-to-your-key.pem>" ubuntu@<Your-Elastic-IP>
cd ~/odoo-erp
```

### Step 3: Pull and Start

```bash
# Set your GitHub username/org in LOWERCASE (must match GH_USER_OR_ORG in .env)
export GH_USER_OR_ORG="<your-github-username-lowercase>"

# Pull the image that GitHub Actions built
docker compose -f docker-compose.yml -f docker-compose.prod.yml pull

# Start all services in the background
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

### Step 3: Initialize the Odoo Database

On first run, Odoo needs a database. You can either:

**Option A: Via the web interface**
Navigate to `https://erp-odoo.automationhr-ai.com` and Odoo will present the database creation wizard. Fill in:
- **Master Password:** The `admin_passwd` from `odoo.conf`
- **Database Name:** e.g., `odoo-prod`
- **Email/Password:** Your admin login credentials
- **Language/Country:** As needed

**Option B: Via the command line**
```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml exec odoo \
  odoo --config=/etc/odoo/odoo.conf -d odoo-prod -i base --stop-after-init --without-demo=all
```

---

## Phase 7: Verify Deployment

### Step 1: Check Container Status

```bash
docker ps
```

You should see 3 containers running:
- `odoo-erp-odoo-1` (Odoo)
- `odoo-erp-db-1` (PostgreSQL)
- `odoo-erp-caddy-1` (Caddy reverse proxy)

### Step 2: Check Caddy Logs (SSL Certificates)

```bash
docker logs odoo-erp-caddy-1
```

Look for lines indicating successful certificate issuance:
```
successfully obtained certificate
```

### Step 3: Check Odoo Logs

```bash
docker logs odoo-erp-odoo-1
```

Look for:
```
INFO ... odoo.service.server: HTTP service (werkzeug) running on ...
```

### Step 4: Access the Site

Open your browser and navigate to:

```
https://erp-odoo.automationhr-ai.com
```

You should see the Odoo login page (or database creation wizard on first visit) with a valid HTTPS certificate.

---

## Ongoing Operations

### Continuous Deployment

After the initial setup, deployments happen automatically:

1. Push code to the `19.0` branch.
2. GitHub Actions builds a new Docker image and pushes it to GHCR.
3. GitHub Actions SSHs to EC2, pulls the new image, and restarts the containers.

You can also trigger a deployment manually from the GitHub Actions tab using the **workflow_dispatch** trigger (click "Run workflow").

### Commands Quick Reference

| Task | Where | Command |
|------|-------|---------|
| **View logs** | EC2 | `cd ~/odoo-erp && docker compose logs -f odoo` |
| **View all logs** | EC2 | `cd ~/odoo-erp && docker compose logs -f` |
| **Restart Odoo** | EC2 | `cd ~/odoo-erp && docker compose -f docker-compose.yml -f docker-compose.prod.yml restart odoo` |
| **Update a module** | EC2 | `docker compose exec odoo odoo -d odoo-prod -u module_name --stop-after-init` |
| **Install a module** | EC2 | `docker compose exec odoo odoo -d odoo-prod -i module_name --stop-after-init` |
| **Database shell** | EC2 | `docker compose exec db psql -U odoo -d odoo-prod` |
| **Stop everything** | EC2 | `cd ~/odoo-erp && docker compose down` |
| **Stop + delete data** | EC2 | `cd ~/odoo-erp && docker compose down -v` (**DESTRUCTIVE**) |
| **Manual deploy** | EC2 | `cd ~/odoo-erp && docker compose -f docker-compose.yml -f docker-compose.prod.yml pull && docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d` |

### Updating Config Files

If you change `docker-compose.yml`, `docker-compose.prod.yml`, `Caddyfile`, or `.env`:

```bash
# From your local machine — re-upload the changed file(s)
scp -i "$KEY" Caddyfile "$HOST":~/odoo-erp/

# SSH in and restart
ssh -i "$KEY" $HOST
cd ~/odoo-erp
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

### Backups

Set up a cron job on the EC2 instance to back up the PostgreSQL database:

```bash
# Create a backup script
cat > ~/odoo-erp/backup.sh << 'SCRIPT'
#!/bin/bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=~/odoo-erp/backups
mkdir -p $BACKUP_DIR

# Dump database
docker compose -C ~/odoo-erp exec -T db pg_dump -U odoo odoo-prod | gzip > "$BACKUP_DIR/odoo-prod_$TIMESTAMP.sql.gz"

# Keep only last 7 days
find $BACKUP_DIR -name "*.sql.gz" -mtime +7 -delete

echo "Backup completed: odoo-prod_$TIMESTAMP.sql.gz"
SCRIPT

chmod +x ~/odoo-erp/backup.sh

# Add to crontab — run daily at 2 AM
(crontab -l 2>/dev/null; echo "0 2 * * * ~/odoo-erp/backup.sh >> ~/odoo-erp/backups/backup.log 2>&1") | crontab -
```

---

## Troubleshooting

### 1. Caddy fails to get SSL certificate

**Symptom:** Caddy logs show ACME challenge failures.

**Fix:** Ensure:
- DNS A record for `erp-odoo.automationhr-ai.com` resolves to the Elastic IP.
- Security Group allows ports 80 and 443 from `0.0.0.0/0`.
- No other process is using ports 80/443 on the host.

```bash
# Verify DNS resolves correctly from the server
dig erp-odoo.automationhr-ai.com

# Check if ports are free
sudo lsof -i :80
sudo lsof -i :443
```

### 2. Odoo shows "Unable to connect to the database"

**Symptom:** 500 error or database connection error on the web page.

**Fix:** Check the database container:

```bash
docker compose logs db
docker compose exec db pg_isready -U odoo
```

Verify the `POSTGRES_PASSWORD` in `.env` matches what Odoo expects in `odoo.conf`.

### 3. SSH connection closes immediately

Run SSH in verbose mode:

```bash
ssh -v -i "<path-to-your-key.pem>" ubuntu@<Your-Elastic-IP>
```

Common causes:
- Wrong key file (downloaded the wrong `.pem`).
- Key file permissions too open (on Linux/Mac: `chmod 400 key.pem`).
- Security Group doesn't allow SSH from your IP.

### 4. GitHub Actions deploy fails

Check the Actions tab in GitHub for error details. Common issues:
- `EC2_SSH_KEY` secret has extra whitespace or missing characters.
- `EC2_HOST` has a typo or the Elastic IP changed.
- Docker image failed to build (check build logs).

### 5. `.env` changes not taking effect

Docker caches environment variables. Force recreation:

```bash
cd ~/odoo-erp
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --force-recreate
```

### 6. Line ending issues in `.env`

If you manually paste content into `.env` from Windows, you may get `\r\n` line endings that break Docker. Always use `scp` to transfer files, or fix with:

```bash
sed -i 's/\r$//' ~/odoo-erp/.env
```

### 7. Disk space running out

Old Docker images accumulate. Clean them up:

```bash
docker system prune -a -f
```

---

## Security Checklist

- [ ] Set a strong `ADMIN_PASSWD` in `.env.prod` (Odoo master password, kept out of git)
- [ ] Set a strong `POSTGRES_PASSWORD` in `.env.prod`
- [ ] SSH key (`odoo-prod-key.pem`) stored securely, not committed to git
- [ ] `.env.prod` and `.env` are in `.gitignore`
- [ ] Security Group only allows SSH from your IP (not `0.0.0.0/0`)
- [ ] `fail2ban` installed and running on the EC2 instance
- [ ] `unattended-upgrades` enabled for automatic security patches
- [ ] Odoo ports (8069, 8072) only bound to `127.0.0.1`, not exposed publicly
- [ ] PostgreSQL port (5432) not exposed publicly
- [ ] Regular database backups configured
