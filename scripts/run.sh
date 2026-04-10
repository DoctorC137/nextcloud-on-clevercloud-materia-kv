#!/bin/bash
# run.sh — CC_PRE_RUN_HOOK
# Reconstructs config.php from env vars + PostgreSQL secrets on every boot.
# First boot: runs occ maintenance:install and persists secrets to PostgreSQL.
# Subsequent boots: reads secrets from PostgreSQL and runs occ upgrade if needed.
set -e

echo "==> Starting Nextcloud..."

# --- Validate required env vars ----------------------------------------------
REQUIRED_VARS=(
    NEXTCLOUD_DOMAIN NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD
    POSTGRESQL_ADDON_DB POSTGRESQL_ADDON_HOST POSTGRESQL_ADDON_PORT
    POSTGRESQL_ADDON_USER POSTGRESQL_ADDON_PASSWORD
    REDIS_HOST REDIS_PORT REDIS_PASSWORD
    CELLAR_ADDON_KEY_ID CELLAR_ADDON_KEY_SECRET CELLAR_ADDON_HOST CELLAR_BUCKET_NAME
)
for VAR in "${REQUIRED_VARS[@]}"; do
    [ -z "${!VAR}" ] && echo "[ERR] Missing env var: $VAR" && exit 1
done
echo "[OK] Environment OK."

REAL_APP=$(cd "$(dirname "$0")/.." && pwd)
# Strip non-numeric chars to prevent silent PHP cast to 0
REDIS_PORT_CLEAN=$(echo "$REDIS_PORT" | tr -dc '0-9')

# --- Ephemeral directories ---------------------------------------------------
mkdir -p "$REAL_APP/config" "$REAL_APP/data" "$REAL_APP/custom_apps" "$REAL_APP/themes"
echo "# Nextcloud data directory" > "$REAL_APP/data/.ncdata"
rm -f "$REAL_APP/config/"*.php 2>/dev/null || true

# --- PHP-FPM config ----------------------------------------------------------
# Sessions are handled natively by Clever Cloud via ENABLE_REDIS=true + SESSION_TYPE=redis env vars.
cat > "$REAL_APP/.user.ini" << EOF
memory_limit = 512M
output_buffering = 0
opcache.max_accelerated_files = 20000
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.revalidate_freq = 60
EOF

# --- PostgreSQL helpers ------------------------------------------------------
db_query() {
    PGPASSWORD="$POSTGRESQL_ADDON_PASSWORD" psql \
        -h "$POSTGRESQL_ADDON_HOST" -p "$POSTGRESQL_ADDON_PORT" \
        -U "$POSTGRESQL_ADDON_USER" -d "$POSTGRESQL_ADDON_DB" \
        -tAc "$1" 2>/dev/null || true
}
db_get() { db_query "SELECT value FROM cc_nextcloud_secrets WHERE key = '$1';"; }
db_set() {
    local key="$1" val
    val=$(echo "$2" | sed "s/'/''/g")
    db_query "INSERT INTO cc_nextcloud_secrets (key, value) VALUES ('${key}', '${val}')
              ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;"
}

# --- Wait for PostgreSQL -----------------------------------------------------
# Clever Cloud place un proxy (Pgpool-II) devant PostgreSQL.
# SELECT 1 peut reussir alors que le proxy n'est pas encore pret pour du DDL.
# On valide avec un DDL leger pour s'assurer que l'install ne sera pas coupee.
echo "[INFO] Waiting for PostgreSQL DDL-ready..."
PG_READY=0
for i in $(seq 1 40); do
    DDL_RESULT=$(db_query "DROP TABLE IF EXISTS _pg_ready_check; CREATE TABLE _pg_ready_check (id int); DROP TABLE _pg_ready_check;" 2>&1)
    if [ $? -eq 0 ] && [ -z "$(echo "$DDL_RESULT" | grep -i error)" ]; then
        echo "[OK] PostgreSQL DDL-ready (attempt $i)."
        PG_READY=1
        break
    fi
    echo "[INFO] PostgreSQL not DDL-ready yet (attempt $i): $(echo "$DDL_RESULT" | tail -1 | cut -c1-80)"
    sleep 5
done
[ "$PG_READY" = "0" ] && echo "[ERR] PostgreSQL timeout after 200s." && exit 1

db_query "CREATE TABLE IF NOT EXISTS cc_nextcloud_secrets (
    key   VARCHAR(255) PRIMARY KEY,
    value TEXT
);"

# --- Pull custom_apps from S3 ------------------------------------------------
echo "[INFO] Pulling custom_apps/ from S3..."
bash "$REAL_APP/scripts/sync-apps.sh" pull || true

# --- Read persisted secrets --------------------------------------------------
NC_INSTANCE_ID=$(db_get "NC_INSTANCE_ID")
NC_PASSWORD_SALT=$(db_get "NC_PASSWORD_SALT")
NC_SECRET=$(db_get "NC_SECRET")
NC_VERSION_STORED=$(db_get "NC_VERSION")

# --- Generate config.php -----------------------------------------------------
# Single source of truth. No config-git fragments to avoid Nextcloud merge conflicts.
# $5 = "no-locking" pour désactiver memcache.locking au premier boot (évite HTTP 423
# sur WebDAV pendant que skeleton.sh initialise le filesystem via WebDAV).
# skeleton.sh réactive le locking dès qu'il a terminé (ou en cas d'échec).
write_config_php() {
    local instanceid="$1" passwordsalt="$2" secret="$3" version="$4" locking="${5:-enabled}"

    local locking_line
    if [ "$locking" = "no-locking" ]; then
        locking_line="  // memcache.locking desactive au premier boot — reactive par skeleton.sh"
    else
        locking_line="  'memcache.locking'     => '\\\\OC\\\\Memcache\\\\Redis',"
    fi

    cat > "$REAL_APP/config/config.php" << EOF
<?php
\$CONFIG = [
  'instanceid'   => '${instanceid}',
  'passwordsalt' => '${passwordsalt}',
  'secret'       => '${secret}',
  'installed'    => true,
  'version'      => '${version}',

  'dbtype'        => 'pgsql',
  'dbname'        => '${POSTGRESQL_ADDON_DB}',
  'dbhost'        => '${POSTGRESQL_ADDON_HOST}:${POSTGRESQL_ADDON_PORT}',
  'dbuser'        => '${POSTGRESQL_ADDON_USER}',
  'dbpassword'    => '${POSTGRESQL_ADDON_PASSWORD}',
  'dbtableprefix' => 'oc_',

  'objectstore' => [
    'class'     => 'OC\\Files\\ObjectStore\\S3',
    'arguments' => [
      'bucket'         => '${CELLAR_BUCKET_NAME}',
      'autocreate'     => true,
      'key'            => '${CELLAR_ADDON_KEY_ID}',
      'secret'         => '${CELLAR_ADDON_KEY_SECRET}',
      'hostname'       => '${CELLAR_ADDON_HOST}',
      'port'           => 443,
      'use_ssl'        => true,
      'region'         => 'us-east-1',
      'use_path_style' => true,
    ],
  ],

  'overwriteprotocol'     => 'https',
  'overwrite.cli.url'     => 'https://${NEXTCLOUD_DOMAIN}',
  'overwritehost'         => '${NEXTCLOUD_DOMAIN}',
  'trusted_domains'       => ['${NEXTCLOUD_DOMAIN}'],
  'trusted_proxies'       => ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'],
  'forwarded_for_headers' => ['HTTP_X_FORWARDED_FOR'],

  // Cache local : APCu (in-process, zero reseau).
  // Cache distribue : Materia KV via Redis-compatible TLS.
  // locking : desactive au premier boot, reactive par skeleton.sh.
  'memcache.local'       => '\\OC\\Memcache\\APCu',
  'memcache.distributed' => '\\OC\\Memcache\\Redis',
${locking_line}
  'redis' => [
    'host'       => 'tls://${REDIS_HOST}',
    'port'       => ${REDIS_PORT_CLEAN},
    'password'   => '${REDIS_PASSWORD}',
    'persistent' => true,
  ],

  'datadirectory'              => '${REAL_APP}/data',
  'allow_local_remote_servers' => true,

  'log_type'                 => 'syslog',
  'loglevel'                 => 2,
  'default_phone_region'     => 'FR',
  'maintenance_window_start' => 1,

  // Désactive l'updater web — les mises à jour passent par install.sh + clever deploy.
  'upgrade.disable-web' => true,
];
EOF
    echo "[OK] config.php written (locking=${locking})."
}

# --- Ensure S3 bucket exists -------------------------------------------------
ensure_s3_bucket() {
    local RCLONE="$REAL_APP/bin/rclone"
    [ ! -f "$RCLONE" ] && echo "[WARN] rclone not found, skipping bucket pre-creation." && return
    echo "[INFO] Ensuring S3 bucket $CELLAR_BUCKET_NAME..."
    "$RCLONE" mkdir \
        --config /dev/null --s3-provider Other \
        --s3-access-key-id "$CELLAR_ADDON_KEY_ID" \
        --s3-secret-access-key "$CELLAR_ADDON_KEY_SECRET" \
        --s3-endpoint "https://$CELLAR_ADDON_HOST" \
        --s3-force-path-style \
        ":s3:${CELLAR_BUCKET_NAME}" 2>&1 \
        && echo "[OK] S3 bucket ready." \
        || echo "[WARN] rclone mkdir failed, Nextcloud will attempt autocreate."
}

# --- Boot: restart or first install ------------------------------------------
if [ -n "$NC_INSTANCE_ID" ] && [ -n "$NC_PASSWORD_SALT" ] && [ -n "$NC_SECRET" ]; then

    echo "[INFO] Secrets found — restarting."
    NC_VERSION="${NC_VERSION_STORED:-0.0.0}"

    # Désactiver locking si skeleton n'a pas encore tourné (même logique que premier boot)
    NC_SKELETON_DONE_R=$(db_get "NC_SKELETON_UPLOADED" 2>/dev/null | tr -d '[:space:]')
    LOCKING_MODE="enabled"
    [ "$NC_SKELETON_DONE_R" != "1" ] && LOCKING_MODE="no-locking"
    write_config_php "$NC_INSTANCE_ID" "$NC_PASSWORD_SALT" "$NC_SECRET" "$NC_VERSION" "$LOCKING_MODE"
    ensure_s3_bucket

    php "$REAL_APP/occ" upgrade --no-interaction 2>&1 || true
    php "$REAL_APP/occ" db:add-missing-indices --no-interaction 2>/dev/null || true

    NC_VERSION_NEW=$(php "$REAL_APP/occ" status --output=json 2>/dev/null \
        | grep -oE '"version":"[^"]*"' | cut -d'"' -f4 || true)
    if [ -n "$NC_VERSION_NEW" ] && [ "$NC_VERSION_NEW" != "$NC_VERSION" ]; then
        echo "[INFO] Version updated: $NC_VERSION → $NC_VERSION_NEW"
        db_set "NC_VERSION" "$NC_VERSION_NEW"
    fi

else

    echo "[INFO] No secrets found — running first install."
    # Retry : le proxy Clever Cloud peut couper la connexion pendant l'install
    # meme apres un DDL check reussi (race condition d'initialisation).
    INSTALL_OK=0
    for attempt in 1 2 3; do
        echo "[INFO] occ maintenance:install — attempt $attempt/3..."
        if php "$REAL_APP/occ" maintenance:install \
            --database=pgsql \
            --database-name="$POSTGRESQL_ADDON_DB" \
            --database-host="$POSTGRESQL_ADDON_HOST:$POSTGRESQL_ADDON_PORT" \
            --database-user="$POSTGRESQL_ADDON_USER" \
            --database-pass="$POSTGRESQL_ADDON_PASSWORD" \
            --admin-user="$NEXTCLOUD_ADMIN_USER" \
            --admin-pass="$NEXTCLOUD_ADMIN_PASSWORD" \
            --data-dir="$REAL_APP/data" \
            --no-interaction; then
            INSTALL_OK=1
            break
        fi
        echo "[WARN] Install attempt $attempt failed, waiting 20s before retry..."
        sleep 20
    done
    [ "$INSTALL_OK" = "0" ] && echo "[ERR] occ maintenance:install failed after 3 attempts." && exit 1

    extract_secret() {
        php -r "\$CONFIG=[]; include '${REAL_APP}/config/config.php'; echo \$CONFIG['$1'] ?? '';" 2>/dev/null || true
    }

    NC_INSTANCE_ID=$(extract_secret "instanceid")
    NC_PASSWORD_SALT=$(extract_secret "passwordsalt")
    NC_SECRET=$(extract_secret "secret")

    # Use occ status "version" field for the full 4-part version (e.g. 33.0.0.16).
    # "versionstring" returns only 3 parts (33.0.0) which causes needsDbUpgrade=true
    # on every restart. "version" returns the full 4-part string.
    NC_VERSION=$(php "$REAL_APP/occ" status --output=json 2>/dev/null \
        | grep -oE '"version":"[^"]*"' | cut -d'"' -f4 || true)
    [ -z "$NC_VERSION" ] && NC_VERSION=$(extract_secret "version")

    if [ -z "$NC_INSTANCE_ID" ] || [ -z "$NC_PASSWORD_SALT" ] || [ -z "$NC_SECRET" ]; then
        echo "[ERR] Failed to extract secrets from config.php:"
        cat "$REAL_APP/config/config.php" || true
        exit 1
    fi

    db_set "NC_INSTANCE_ID"   "$NC_INSTANCE_ID"
    db_set "NC_PASSWORD_SALT" "$NC_PASSWORD_SALT"
    db_set "NC_SECRET"        "$NC_SECRET"
    db_set "NC_VERSION"       "$NC_VERSION"

    # Premier boot : locking désactivé pour éviter HTTP 423 sur WebDAV pendant
    # que skeleton.sh initialise le filesystem. skeleton.sh le réactive ensuite.
    write_config_php "$NC_INSTANCE_ID" "$NC_PASSWORD_SALT" "$NC_SECRET" "$NC_VERSION" "no-locking"
    ensure_s3_bucket

    # occ upgrade necessaire au premier boot : config.php a ete recrit avec la
    # version 4 chiffres, Nextcloud doit aligner son schema BDD.
    php "$REAL_APP/occ" upgrade --no-interaction 2>&1 || true
    php "$REAL_APP/occ" db:add-missing-indices --no-interaction 2>/dev/null || true
    php "$REAL_APP/occ" maintenance:repair --include-expensive --no-interaction 2>/dev/null || true
    echo "[OK] First install complete."

fi

# --- Idempotent settings (applied on every boot) -----------------------------
php "$REAL_APP/occ" config:app:set core backgroundjobs_mode --value=webcron --no-interaction 2>/dev/null || true
php "$REAL_APP/occ" maintenance:mode --off --no-interaction 2>/dev/null || true

# --- Purge DAV locks orphelins (boots suivants) ------------------------------
# Au premier boot, memcache.locking est desactive — pas de locks Redis a purger.
# Aux boots suivants, Materia KV conserve les locks entre redemarrages :
# FLUSHDB au boot est sur car Apache n'a pas encore demarre.
NC_SKELETON_DONE=$(db_get "NC_SKELETON_UPLOADED" 2>/dev/null | tr -d '[:space:]')
if [ "$NC_SKELETON_DONE" = "1" ]; then
    php "$REAL_APP/occ" dav:cleanup-chunks --no-interaction 2>/dev/null || true
    echo "[INFO] Purge des locks orphelins dans Materia KV (FLUSHDB)..."
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT_CLEAN" --tls \
        -a "$REDIS_PASSWORD" --no-auth-warning FLUSHDB \
        && echo "[OK] Materia KV purgé." \
        || echo "[WARN] FLUSHDB échoué (non bloquant)."
else
    echo "[INFO] Premier boot — memcache.locking désactivé, pas de FLUSHDB nécessaire."
fi
echo "[OK] DAV locks purged."

echo "[OK] Nextcloud ready: https://$NEXTCLOUD_DOMAIN"
