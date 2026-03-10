![Clever Cloud logo](github-assets/clever-cloud-logo.png)

# Nextcloud on Clever Cloud — no FS Bucket
[![Clever Cloud - PaaS](https://img.shields.io/badge/Clever%20Cloud-PaaS-orange)](https://clever-cloud.com)
[![Nextcloud](https://img.shields.io/badge/Nextcloud-33-0082C9?logo=nextcloud)](https://nextcloud.com)

> **POC branch** — FS Bucket-free architecture. Config is reconstructed from environment variables on every start. Validated: first install + restart with persistent user data. See `main` for the stable FS Bucket-based version.

Production-ready deployment of [Nextcloud](https://nextcloud.com) on Clever Cloud without a FS Bucket addon. Nextcloud's generated secrets (`instanceid`, `passwordsalt`, `secret`) are stored as Clever Cloud environment variables via the platform API after first install, and `config.php` is fully rebuilt from env vars on every subsequent restart.

---

## Architecture

| Service | Role |
|---|---|
| **PHP Application** | Runs Nextcloud (Apache + PHP-FPM) |
| **PostgreSQL** | Main database |
| **Redis** | Distributed cache (sessions, locks) |
| **Cellar S3** | Objectstore for user-uploaded files + `config.php` secrets stored as env vars |

> No FS Bucket. `config/`, `data/`, `custom_apps/`, `themes/` are local ephemeral directories — user files live on S3, secrets live in env vars.

---

## Integration challenges and solutions

### Ephemeral local disk

Nextcloud writes its config to `config/config.php` and data to `data/`. Both are lost on every Clever Cloud cycle. Instead of persisting them on a FS Bucket, `run.sh` fully reconstructs `config.php` from environment variables at each startup.

### Secrets persistence

`maintenance:install` generates three secrets — `instanceid`, `passwordsalt`, `secret` — that must remain stable across restarts (sessions, shares, and encryption depend on them). After first install, `run.sh` extracts them from the generated `config.php` and stores them in the PostgreSQL table `cc_nextcloud_secrets`. On subsequent starts they are read from the database and used to rebuild `config.php` from scratch.

### S3 objectstore

The objectstore backend must be present in config before the first `maintenance:install` — it cannot be enabled via `occ` post-install. Cellar credentials are injected via `config-git/20-objectstore.config.php`, loaded automatically by Nextcloud from `config/` using its fragmented config mechanism. All secrets come from Clever Cloud environment variables.

### Idempotent startup

`run.sh` detects the boot type via env vars: `NC_INSTANCE_ID` absent → first install; present → reconstruct `config.php` and run `occ upgrade`. PostgreSQL availability is polled with `SELECT 1` before install.

### Skeleton upload

Uploading example files via WebDAV requires Apache running and the S3 objectstore ready — neither holds true during `CC_PRE_RUN_HOOK`. `skeleton.sh` runs via `CC_RUN_SUCCEEDED_HOOK` and calls WebDAV on `localhost:$PORT` (outbound network is restricted in this hook context).

### Background jobs (cron)

Clever Cloud's crontab entries are stored in a non-standard path that `crond` does not read. **Webcron mode** is enabled: Nextcloud triggers background jobs on each HTTP request. `clevercloud/cron.json` additionally registers a native Clever Cloud cron that curls `/cron.php` every 5 minutes as a fallback.

### Major version migration

Nextcloud blocks version skips across majors. `install.sh` resolves the target version, compares it to the installed one, and applies upgrades step by step (e.g. 30→31→32→33) before `run.sh` calls `occ upgrade`.

---

## Repository structure

```
.
├── .user.ini                          # PHP-FPM tuning: memory_limit, opcache
├── clevercloud/
│   └── cron.json                      # Native CC cron — curls /cron.php every 5 min
├── config-git/
│   ├── 10-clevercloud.config.php      # Network, DB, Redis, trusted proxies
│   └── 20-objectstore.config.php      # Cellar S3 objectstore
├── scripts/
│   ├── install.sh                     # CC_POST_BUILD_HOOK — downloads/upgrades Nextcloud
│   ├── run.sh                         # CC_PRE_RUN_HOOK    — rebuild config.php, install/upgrade
│   ├── cron.sh                        # Called by cron.json
│   └── skeleton.sh                    # CC_RUN_SUCCEEDED_HOOK — uploads example files
├── deploy/
│   └── clever-deploy.sh               # Interactive full provisioning script (no FS Bucket)
└── tools/
    └── clever-destroy.sh              # Full teardown (dev/test only)
```

---

## Deployment

### Prerequisites

```bash
npm install -g clever-tools
clever login
```

### First deployment

#### 1. Create your repo from this template

Click **Use this template → Create a new repository** at the top of this page, then clone your new repo:

```bash
git clone git@github.com:<you>/nextcloud-on-clevercloud.git
```

#### 2. Run the provisioning script

```bash
bash deploy/clever-deploy.sh
```

The script provisions the PHP app, PostgreSQL, Redis and Cellar (no FS Bucket), injects all environment variables, and triggers the deployment. First startup takes **2–5 minutes** (Nextcloud install + DB seed + secrets persistence via API).

### Redeploy

```bash
git push origin poc/no-fsbucket
# or
clever deploy --alias nextcloud --force
```

### Pin a Nextcloud version

```bash
clever env set NEXTCLOUD_VERSION 32.0.6 --alias nextcloud
clever deploy --alias nextcloud --force

# back to latest:
clever env unset NEXTCLOUD_VERSION --alias nextcloud
```

### Logs / SSH

```bash
clever logs --alias nextcloud
clever ssh --alias nextcloud
```

### Teardown

```bash
bash tools/clever-destroy.sh nextcloud [orga_xxx]
```

---

## Known warnings

These appear in Administration → Overview. All are non-blocking.

| Warning | Explanation |
|---|---|
| **Code integrity** | Custom files outside Nextcloud's distribution detected (scripts, config-git, .git) — expected |
| **HSTS** | Header managed by Clever Cloud's reverse proxy, not configurable from the app |
| **PHP 8.2** | Managed by Clever Cloud via `CC_PHP_VERSION` |
| **OPcache max_accelerated_files** | `.user.ini` applies to PHP-FPM only — PHP CLI reads system config |
| **APCu missing** | `CC_PHP_EXTENSIONS=apcu` loads the extension for PHP-FPM; Nextcloud's check runs via PHP CLI where it's unavailable |
| **AppAPI** | Optional Docker-based feature, unrelated to this deployment |
| **Log errors** | `Skipping updater backup clean-up` — backup folder absent since the web updater has never run |

---

## Additional resources

- [Clever Cloud Documentation](https://www.clever-cloud.com/doc/)
- [Nextcloud Admin Documentation](https://docs.nextcloud.com/server/latest/admin_manual/)
- [Clever Tools CLI](https://github.com/CleverCloud/clever-tools)
- [Clever Cloud Status](https://status.clever-cloud.com/)
