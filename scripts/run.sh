#!/bin/bash
# =============================================================================
# run.sh — CC_PRE_RUN_HOOK — POC no-fsbucket
# Sans FS Bucket : config.php reconstruit depuis env vars à chaque démarrage.
# Les secrets générés au premier install (instanceid, passwordsalt, secret)
# sont stockés comme variables d'environnement Clever Cloud via l'API.
# =============================================================================

set -e

echo "==> Démarrage Nextcloud (POC no-fsbucket)..."

# -----------------------------------------------------------------------------
# Variables obligatoires
# -----------------------------------------------------------------------------
REQUIRED_VARS=(
    NEXTCLOUD_DOMAIN NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD
    POSTGRESQL_ADDON_DB POSTGRESQL_ADDON_HOST POSTGRESQL_ADDON_PORT
    POSTGRESQL_ADDON_USER POSTGRESQL_ADDON_PASSWORD
    REDIS_HOST REDIS_PORT REDIS_PASSWORD
    CELLAR_ADDON_KEY_ID CELLAR_ADDON_KEY_SECRET CELLAR_ADDON_HOST CELLAR_BUCKET_NAME
    CC_APP_ID CC_ENVIRON_UPDATE_TOKEN CC_ENVIRON_UPDATE_URL
)
MISSING=0
for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR}" ]; then echo "[ERR] Variable manquante : $VAR"; MISSING=1; fi
done
[ "$MISSING" -eq 1 ] && echo "[ERR] Variables manquantes, arrêt." && exit 1
echo "[OK] Variables d'environnement OK."

REAL_APP=$(cd "$(dirname "$0")/.." && pwd)
echo "[INFO] REAL_APP=$REAL_APP"

# -----------------------------------------------------------------------------
# Dossiers locaux (éphémères — recréés à chaque démarrage)
# data/ est vide mais requis par Nextcloud (les fichiers sont sur S3)
# -----------------------------------------------------------------------------
mkdir -p \
    "$REAL_APP/config" \
    "$REAL_APP/data" \
    "$REAL_APP/custom_apps" \
    "$REAL_APP/themes"

# -----------------------------------------------------------------------------
# Copie des fichiers de config fragmentée dans config/
# -----------------------------------------------------------------------------
cp "$REAL_APP/config-git/"*.config.php "$REAL_APP/config/" 2>/dev/null || true

# -----------------------------------------------------------------------------
# .user.ini — PHP-FPM tuning
# -----------------------------------------------------------------------------
cat > "$REAL_APP/.user.ini" << 'EOF'
memory_limit = 512M
output_buffering = 0
opcache.max_accelerated_files = 20000
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.revalidate_freq = 60
EOF

# -----------------------------------------------------------------------------
# Fonction : stocker une variable d'environnement via l'API Clever Cloud
# -----------------------------------------------------------------------------
cc_env_set() {
    local KEY="$1"
    local VALUE="$2"
    curl -sf -X PUT \
        "${CC_ENVIRON_UPDATE_URL}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${CC_ENVIRON_UPDATE_TOKEN}" \
        -d "{\"name\":\"${KEY}\",\"value\":\"${VALUE}\"}" \
        >/dev/null 2>&1 \
        && echo "[OK] Env var persistée : $KEY" \
        || echo "[WARN] Impossible de persister $KEY via API"
}

# -----------------------------------------------------------------------------
# Helper : extraire une clé de config.php (qui définit $CONFIG, pas $c)
# -----------------------------------------------------------------------------
extract_nc_config() {
    local KEY="$1"
    php -r "
        \$CONFIG = [];
        include '${REAL_APP}/config/config.php';
        echo \$CONFIG['${KEY}'] ?? '';
    " 2>/dev/null
}

# -----------------------------------------------------------------------------
# Détection : premier démarrage ou redémarrage
# -----------------------------------------------------------------------------
if [ -n "$NC_INSTANCE_ID" ] && [ -n "$NC_PASSWORD_SALT" ] && [ -n "$NC_SECRET" ]; then
    # -------------------------------------------------------------------------
    # REDÉMARRAGE — reconstruire config.php depuis les env vars
    # -------------------------------------------------------------------------
    echo "[INFO] Secrets détectés — redémarrage, reconstruction de config.php."

    NC_VERSION=$(php "$REAL_APP/occ" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    cat > "$REAL_APP/config/config.php" << EOF
<?php
\$CONFIG = [
  'instanceid'     => '${NC_INSTANCE_ID}',
  'passwordsalt'   => '${NC_PASSWORD_SALT}',
  'secret'         => '${NC_SECRET}',
  'installed'      => true,
  'version'        => '${NC_VERSION}',
  'dbtype'         => 'pgsql',
  'dbname'         => '${POSTGRESQL_ADDON_DB}',
  'dbhost'         => '${POSTGRESQL_ADDON_HOST}:${POSTGRESQL_ADDON_PORT}',
  'dbuser'         => '${POSTGRESQL_ADDON_USER}',
  'dbpassword'     => '${POSTGRESQL_ADDON_PASSWORD}',
  'dbtableprefix'  => 'oc_',
  'datadirectory'  => '${REAL_APP}/data',
  'allow_local_remote_servers' => true,
];
EOF
    echo "[OK] config.php reconstruit depuis env vars."

    php "$REAL_APP/occ" upgrade --no-interaction 2>/dev/null || true
    php "$REAL_APP/occ" db:add-missing-indices --no-interaction 2>/dev/null || true

else
    # -------------------------------------------------------------------------
    # PREMIER DÉMARRAGE — installation complète
    # -------------------------------------------------------------------------
    echo "[INFO] Aucun secret détecté — premier démarrage."

    echo "[INFO] Attente de PostgreSQL..."
    PG_READY=0
    for i in $(seq 1 30); do
        if PGPASSWORD="$POSTGRESQL_ADDON_PASSWORD" psql \
            -h "$POSTGRESQL_ADDON_HOST" \
            -p "$POSTGRESQL_ADDON_PORT" \
            -U "$POSTGRESQL_ADDON_USER" \
            -d "$POSTGRESQL_ADDON_DB" \
            -c "SELECT 1;" >/dev/null 2>&1; then
            PG_READY=1
            echo "[OK] PostgreSQL prêt après $i tentative(s)."
            break
        fi
        sleep 3
    done
    [ "$PG_READY" = "0" ] && echo "[ERR] Timeout — PostgreSQL non disponible." && exit 1

    php "$REAL_APP/occ" maintenance:install \
        --database=pgsql \
        --database-name="$POSTGRESQL_ADDON_DB" \
        --database-host="$POSTGRESQL_ADDON_HOST:$POSTGRESQL_ADDON_PORT" \
        --database-user="$POSTGRESQL_ADDON_USER" \
        --database-pass="$POSTGRESQL_ADDON_PASSWORD" \
        --admin-user="$NEXTCLOUD_ADMIN_USER" \
        --admin-pass="$NEXTCLOUD_ADMIN_PASSWORD" \
        --data-dir="$REAL_APP/data" \
        --no-interaction

    # -------------------------------------------------------------------------
    # Extraction des secrets générés par Nextcloud depuis config.php
    # config.php définit $CONFIG (pas $c) — utiliser extract_nc_config()
    # -------------------------------------------------------------------------
    NC_INSTANCE_ID=$(extract_nc_config "instanceid")
    NC_PASSWORD_SALT=$(extract_nc_config "passwordsalt")
    NC_SECRET=$(extract_nc_config "secret")

    echo "[DEBUG] instanceid='$NC_INSTANCE_ID'"
    echo "[DEBUG] passwordsalt length=${#NC_PASSWORD_SALT}"
    echo "[DEBUG] secret length=${#NC_SECRET}"

    if [ -z "$NC_INSTANCE_ID" ] || [ -z "$NC_PASSWORD_SALT" ] || [ -z "$NC_SECRET" ]; then
        echo "[ERR] Impossible d'extraire les secrets depuis config.php."
        echo "[ERR] Contenu config.php :"
        cat "$REAL_APP/config/config.php" || echo "[ERR] config.php introuvable"
        exit 1
    fi

    echo "[INFO] Secrets extraits — persistance via API Clever Cloud..."
    cc_env_set "NC_INSTANCE_ID"   "$NC_INSTANCE_ID"
    cc_env_set "NC_PASSWORD_SALT" "$NC_PASSWORD_SALT"
    cc_env_set "NC_SECRET"        "$NC_SECRET"

    # -------------------------------------------------------------------------
    # Config réseau, Redis, trusted proxies
    # -------------------------------------------------------------------------
    php "$REAL_APP/occ" config:system:set trusted_domains 0 --value="$NEXTCLOUD_DOMAIN" --no-interaction
    php "$REAL_APP/occ" config:system:set overwrite.cli.url --value="https://$NEXTCLOUD_DOMAIN" --no-interaction
    php "$REAL_APP/occ" config:system:set overwriteprotocol --value="https" --no-interaction
    php "$REAL_APP/occ" config:system:set overwritehost --value="$NEXTCLOUD_DOMAIN" --no-interaction
    php "$REAL_APP/occ" config:system:set forwarded_for_headers 0 --value="HTTP_X_FORWARDED_FOR" --no-interaction
    php "$REAL_APP/occ" config:system:set trusted_proxies 0 --value="10.0.0.0/8" --no-interaction
    php "$REAL_APP/occ" config:system:set trusted_proxies 1 --value="172.16.0.0/12" --no-interaction
    php "$REAL_APP/occ" config:system:set trusted_proxies 2 --value="192.168.0.0/16" --no-interaction
    php "$REAL_APP/occ" config:system:set redis host --value="$REDIS_HOST" --no-interaction
    php "$REAL_APP/occ" config:system:set redis port --value="$REDIS_PORT" --no-interaction
    php "$REAL_APP/occ" config:system:set redis password --value="$REDIS_PASSWORD" --no-interaction
    php "$REAL_APP/occ" config:system:set memcache.local       --value='\OC\Memcache\Redis' --no-interaction
    php "$REAL_APP/occ" config:system:set memcache.distributed --value='\OC\Memcache\Redis' --no-interaction
    php "$REAL_APP/occ" config:system:set memcache.locking     --value='\OC\Memcache\Redis' --no-interaction

    php "$REAL_APP/occ" db:add-missing-indices --no-interaction 2>/dev/null || true
    php "$REAL_APP/occ" maintenance:repair --include-expensive --no-interaction 2>/dev/null || true

    echo "[OK] Installation Nextcloud terminée."
fi

# -----------------------------------------------------------------------------
# Paramètres idempotents
# -----------------------------------------------------------------------------
php "$REAL_APP/occ" config:system:set maintenance_window_start --value=1 --type=integer --no-interaction 2>/dev/null || true
php "$REAL_APP/occ" config:system:set default_phone_region --value="FR" --no-interaction 2>/dev/null || true
php "$REAL_APP/occ" config:app:set core backgroundjobs_mode --value webcron --no-interaction 2>/dev/null || true
php "$REAL_APP/occ" maintenance:mode --off --no-interaction 2>/dev/null || true

# -----------------------------------------------------------------------------
# Crontab
# -----------------------------------------------------------------------------
mkdir -p /home/bas/.cache/crontab
echo "*/5 * * * * $REAL_APP/scripts/cron.sh" | crontab -
echo "[OK] Crontab mise à jour : $REAL_APP/scripts/cron.sh"

echo "[OK] Nextcloud prêt : https://$NEXTCLOUD_DOMAIN"
