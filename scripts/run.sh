#!/bin/bash
# =============================================================================
# run.sh — CC_PRE_RUN_HOOK — no-fsbucket
# Secrets persistés dans PostgreSQL pour une robustesse absolue.
# =============================================================================
set -e
echo "==> Démarrage Nextcloud (no-fsbucket)..."

REQUIRED_VARS=(
    NEXTCLOUD_DOMAIN NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD
    POSTGRESQL_ADDON_DB POSTGRESQL_ADDON_HOST POSTGRESQL_ADDON_PORT
    POSTGRESQL_ADDON_USER POSTGRESQL_ADDON_PASSWORD
    REDIS_HOST REDIS_PORT REDIS_PASSWORD
    CELLAR_ADDON_KEY_ID CELLAR_ADDON_KEY_SECRET CELLAR_ADDON_HOST CELLAR_BUCKET_NAME
)
for VAR in "${REQUIRED_VARS[@]}"; do
    [ -z "${!VAR}" ] && echo "[ERR] Manque : $VAR" && exit 1
done

REAL_APP=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$REAL_APP/config" "$REAL_APP/data" "$REAL_APP/custom_apps" "$REAL_APP/themes"
cp "$REAL_APP/config-git/"*.config.php "$REAL_APP/config/" 2>/dev/null || true

cat > "$REAL_APP/.user.ini" << 'EOF'
memory_limit = 512M
output_buffering = 0
opcache.max_accelerated_files = 20000
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.revalidate_freq = 60
EOF

db_query() {
    PGPASSWORD="$POSTGRESQL_ADDON_PASSWORD" psql -h "$POSTGRESQL_ADDON_HOST" -p "$POSTGRESQL_ADDON_PORT" -U "$POSTGRESQL_ADDON_USER" -d "$POSTGRESQL_ADDON_DB" -tAc "$1" 2>/dev/null || true
}
db_get_secret() { db_query "SELECT value FROM cc_nextcloud_secrets WHERE key = '$1';"; }
db_set_secret() { db_query "INSERT INTO cc_nextcloud_secrets (key, value) VALUES ('$1', '$2') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;"; }

echo "[INFO] Attente de PostgreSQL..."
PG_READY=0
for i in $(seq 1 30); do
    if db_query "SELECT 1;" | grep -q 1; then PG_READY=1; break; fi
    sleep 3
done[ "$PG_READY" = "0" ] && echo "[ERR] Timeout PostgreSQL." && exit 1

db_query "CREATE TABLE IF NOT EXISTS cc_nextcloud_secrets (key VARCHAR(255) PRIMARY KEY, value TEXT);"

extract_nc_config() {
    php -r "\$CONFIG =[]; include '${REAL_APP}/config/config.php'; echo \$CONFIG['$1'] ?? '';" 2>/dev/null
}

echo "[INFO] Synchronisation custom_apps/ depuis S3..."
bash "$REAL_APP/scripts/sync-apps.sh" pull || true

NC_INSTANCE_ID=$(db_get_secret "NC_INSTANCE_ID")
NC_PASSWORD_SALT=$(db_get_secret "NC_PASSWORD_SALT")
NC_SECRET=$(db_get_secret "NC_SECRET")

if [ -n "$NC_INSTANCE_ID" ] &&[ -n "$NC_PASSWORD_SALT" ] && [ -n "$NC_SECRET" ]; then
    echo "[INFO] Secrets trouvés en BDD — redémarrage."
    NC_VERSION_CURRENT=$(db_get_secret "NC_VERSION")
    [ -z "$NC_VERSION_CURRENT" ] && NC_VERSION_CURRENT=$(php "$REAL_APP/occ" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    cat > "$REAL_APP/config/config.php" << EOF
<?php
\$CONFIG =[
  'instanceid'                 => '${NC_INSTANCE_ID}',
  'passwordsalt'               => '${NC_PASSWORD_SALT}',
  'secret'                     => '${NC_SECRET}',
  'installed'                  => true,
  'version'                    => '${NC_VERSION_CURRENT}',
  'dbtype'                     => 'pgsql',
  'dbname'                     => '${POSTGRESQL_ADDON_DB}',
  'dbhost'                     => '${POSTGRESQL_ADDON_HOST}:${POSTGRESQL_ADDON_PORT}',
  'dbuser'                     => '${POSTGRESQL_ADDON_USER}',
  'dbpassword'                 => '${POSTGRESQL_ADDON_PASSWORD}',
  'dbtableprefix'              => 'oc_',
  'datadirectory'              => '${REAL_APP}/data',
  'allow_local_remote_servers' => true,
];
EOF
    php "$REAL_APP/occ" upgrade --no-interaction 2>/dev/null || true
    php "$REAL_APP/occ" db:add-missing-indices --no-interaction 2>/dev/null || true
else
    echo "[INFO] Aucun secret en BDD — installation complète."
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

    NC_INSTANCE_ID=$(extract_nc_config "instanceid")
    NC_PASSWORD_SALT=$(extract_nc_config "passwordsalt")
    NC_SECRET=$(extract_nc_config "secret")
    NC_VERSION_INSTALLED=$(extract_nc_config "version" | cut -d. -f1-3)
    
    [ -z "$NC_INSTANCE_ID" ] && echo "[ERR] Impossible d'extraire les secrets." && exit 1

    echo "[INFO] Sauvegarde des secrets en BDD..."
    db_set_secret "NC_INSTANCE_ID" "$NC_INSTANCE_ID"
    db_set_secret "NC_PASSWORD_SALT" "$NC_PASSWORD_SALT"
    db_set_secret "NC_SECRET" "$NC_SECRET"
    db_set_secret "NC_VERSION" "$NC_VERSION_INSTALLED"

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
fi

php "$REAL_APP/occ" config:system:set maintenance_window_start --value=1 --type=integer --no-interaction 2>/dev/null || true
php "$REAL_APP/occ" config:system:set default_phone_region --value="FR" --no-interaction 2>/dev/null || true
php "$REAL_APP/occ" config:app:set core backgroundjobs_mode --value webcron --no-interaction 2>/dev/null || true
php "$REAL_APP/occ" config:system:set log_type --value="syslog" --no-interaction 2>/dev/null || true
php "$REAL_APP/occ" config:system:set loglevel --value=2 --type=integer --no-interaction 2>/dev/null || true
php "$REAL_APP/occ" maintenance:mode --off --no-interaction 2>/dev/null || true

echo "[OK] Nextcloud prêt : https://$NEXTCLOUD_DOMAIN"