#!/bin/bash -l
# =============================================================================
# cron.sh — Cron Nextcloud pour Clever Cloud
# Appelé via clevercloud/cron.json toutes les 5 minutes.
# Le -l dans le shebang est obligatoire pour accéder aux variables d'env CC.
# Sans FS Bucket : logs vers syslog (visible dans clever logs --alias nextcloud)
# =============================================================================

REAL_APP=$(ls -d /home/bas/app_*/ 2>/dev/null | head -1 | sed 's|/$||')
[ -z "$REAL_APP" ] && exit 1

php "$REAL_APP/cron.php" 2>&1 | logger -t nextcloud-cron
