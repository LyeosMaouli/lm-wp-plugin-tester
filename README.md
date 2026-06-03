# lm-wp-plugin-tester

Local Docker stack for testing WordPress plugins on Windows with HTTPS.

The repo owns the WordPress test environment. Plugin source folders live in `plugins/`, which is intentionally ignored by git so any plugin can be dropped in locally without coupling this tester to one project.

## First-time setup

From the repo root:

```powershell
Copy-Item .env.example .env
```

Edit `.env` and set a local admin password:

```dotenv
WP_ADMIN_PASSWORD=YOUR_LOCAL_PASSWORD
```

Then start the environment:

```powershell
.\start-local.ps1
```

The startup script checks for WSL Ubuntu, Docker Desktop, Git, Node.js LTS, mkcert, and trusted localhost certificates. Missing localhost certificates are generated under `docker\certs`.

WordPress defaults:

- URL: `https://localhost`
- Site title: `WordPress Plugin Tester`
- Admin user: `admin`
- Admin email: `admin@local.test`

## Local plugin workspace

Put plugin folders under `plugins\`:

```text
plugins\
  my-plugin\
    my-plugin.php
```

The whole `plugins\` directory is mounted into the containers at:

```text
/var/www/html/wp-content/plugins
```

Plugin activation is manual:

```powershell
docker compose run --rm --user 33:33 -e HOME=/tmp wpcli wp plugin list
docker compose run --rm --user 33:33 -e HOME=/tmp wpcli wp plugin activate my-plugin
```

Use the plugin's own tooling from its local folder when needed:

```powershell
cd plugins\my-plugin
npm install
npm run dev
```

## Daily use

```powershell
.\start-local.ps1
```

Open:

- `https://localhost`
- `https://localhost/wp-admin`

If WordPress is already installed, the script starts the stack and skips the core install.

## Debugging

Each `.\start-local.ps1` run writes a PowerShell transcript and Docker diagnostics under `logs\`:

- `start-local-YYYYMMDD-HHMMSS.log`
- `docker-compose-YYYYMMDD-HHMMSS-status.log`
- `docker-compose-YYYYMMDD-HHMMSS.log`

```powershell
docker compose logs -f
docker compose logs -f wordpress
docker compose logs -f caddy
docker compose exec wordpress bash -lc "tail -f /var/www/html/wp-content/debug.log"
```

## Reset

This removes the WordPress and database volumes:

```powershell
docker compose down -v
.\start-local.ps1
```

After a reset, activate any local plugins again with WP-CLI or the WordPress admin.

## Verification

```powershell
docker compose config
docker compose exec wordpress php -v
docker compose run --rm --user 33:33 -e HOME=/tmp wpcli wp plugin list
```

Expect PHP 8.4.x in the WordPress container.

## Troubleshooting

If Caddy cannot start because ports 80 or 443 are already allocated, stop the other local web server or Docker stack that is publishing those ports, then run `.\start-local.ps1` again.
