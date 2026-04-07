# Odoo 19.0 — Custom Deployment Fork

## Project Overview
This is a fork of [Odoo 19.0 Community Edition](https://github.com/odoo/odoo), maintained for commercial deployment, integration, commissioning, support, and training services.

## Branch
- **Main branch:** `19.0`
- Upstream: `odoo/odoo` branch `19.0`

## Architecture
- **Framework:** Python (Werkzeug-based web framework + ORM)
- **Database:** PostgreSQL (required, no alternatives)
- **Frontend:** Owl (Odoo Web Library) components + legacy JS
- **Key entry point:** `odoo-bin` (root of repo) — starts the server
- **Config:** `odoo.conf` or CLI flags
- **Addons:** `addons/` (official), `odoo/addons/` (base), mount custom addons via `extra-addons/`

## Deployment
Target deployment: **AWS EC2 with Docker Compose**

```bash
# Build and start
docker compose up -d --build

# View logs
docker compose logs -f odoo

# Stop
docker compose down
```

- Odoo web: port `8069`
- Longpolling: port `8072`
- PostgreSQL: port `5432` (internal only)

## Development Commands
```bash
# Run Odoo locally (dev mode)
python odoo-bin --addons-path=addons,odoo/addons -d mydb

# Run tests for a specific module
python odoo-bin -d testdb --test-enable --stop-after-init -i module_name

# Update a module
python odoo-bin -d mydb -u module_name --stop-after-init
```

## Conventions
- Follow Odoo coding guidelines: https://www.odoo.com/documentation/19.0/contributing/development/coding_guidelines.html
- Commit messages: `[TAG] module_name: description` (e.g., `[FIX] sale: correct tax computation`)
- Tags: `[FIX]`, `[IMP]`, `[ADD]`, `[REM]`, `[REF]`, `[MOV]`, `[I18N]`
