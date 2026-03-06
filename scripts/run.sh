#!/bin/bash
# =============================================================================
# run.sh — CC_PRE_RUN_HOOK — no-fsbucket
# Secrets et état persistés dans PostgreSQL (table cc_nextcloud_secrets).
# Le config.php est reconstruit intégralement à chaque démarrage depuis :
#   - les secrets lus en BDD (instanceid, passwordsalt, secret)
#   - les variables d'environnement Clever Cloud (DB, Redis, domaine...)
# Les fichiers config-git/*.config.php NE sont PAS copiés dans config/ pour
# éviter tout conflit : un seul config.php complet est généré ici.
# =============================================================================
set -e

echo "==> Démarrage Nextcloud (no-fsbucket)..."

# -----------------------------------------------------------------------------
# Variables obligatoires
# -----------------------------------------------------------------------------
REQUIRED_VARS=(
    NEXTCLOUD_DOMAIN NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD
    POSTGRESQL_ADDON_DB POSTGRESQL_ADDON_HOST POSTGRESQL_ADDON_PORT
    POSTGRESQL_ADDON_USER POSTGRESQL_ADDON_PASSWORD
    REDIS_HOST REDIS_PORT REDIS_PASSWORD
    CELLAR_ADDON_KEY_ID CELLAR_ADDON_KEY_SECRET CELLAR_ADDON_HOST CELLAR_BUCKET_NAME
)
for VAR in "${REQUIRED_VARS[@]}"; do
    [ -z "${!VAR}" ] && echo "[ERR] Variable manquante : $VAR" && exit 1
done
echo "[OK] Variables d'environnement OK."

REAL_APP=$(cd "$(dirname "$0")/.." && pwd)
echo "[INFO] REAL_APP=$REAL_APP"

# -----------------------------------------------------------------------------
# Dossiers locaux (éphémères, recréés à chaque démarrage)
# -----------------------------------------------------------------------------
mkdir -p "$REAL_APP/config" "$REAL_APP/data" "$REAL_APP/custom_apps" "$REAL_APP/themes"

# On vide config/ pour éviter tout conflit avec d'anciens fragments
rm -f "$REAL_APP/config/"*.php 2>/dev/null || true

# -----------------------------------------------------------------------------
# PHP-FPM tuning
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
# Helpers PostgreSQL
# -----------------------------------------------------------------------------
db_query() {
    PGPASSWORD="$POSTGRESQL_ADDON_PASSWORD" psql \
        -h "$POSTGRESQL_ADDON_HOST" \
        -p "$POSTGRESQL_ADDON_PORT" \
        -U "$POSTGRESQL_ADDON_USER" \
        -d "$POSTGRESQL_ADDON_DB" \
        -tAc "$1" 2>/dev/null || true
}
db_get() { db_query "SELECT value FROM cc_nextcloud_secrets WHERE key = '$1';"; }
db_set() {
    db_query "INSERT INTO cc_nextcloud_secrets (key, value)
              VALUES ('$1', '$2')
              ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;"
}

# -----------------------------------------------------------------------------
# Attente PostgreSQL
# -----------------------------------------------------------------------------
echo "[INFO] Attente de PostgreSQL..."
PG_READY=0
for i in $(seq 1 30); do
    if db_query "SELECT 1;" | grep -q 1; then
        PG_READY=1
        echo "[OK] PostgreSQL prêt après $i tentative(s)."
        break
    fi
    sleep 3
done
[ "$PG_READY" = "0" ] && echo "[ERR] Timeout PostgreSQL." && exit 1

# Création de la table de persistance si elle n'existe pas
db_query "CREATE TABLE IF NOT EXISTS cc_nextcloud_secrets (
    key   VARCHAR(255) PRIMARY KEY,
    value TEXT
);"

# -----------------------------------------------------------------------------
# Sync custom_apps/ depuis S3 (pull systématique au boot)
# -----------------------------------------------------------------------------
echo "[INFO] Synchronisation custom_apps/ depuis S3..."
bash "$REAL_APP/scripts/sync-apps.sh" pull || true

# -----------------------------------------------------------------------------
# Lecture des secrets en BDD
# -----------------------------------------------------------------------------
NC_INSTANCE_ID=$(db_get "NC_INSTANCE_ID")
NC_PASSWORD_SALT=$(db_get "NC_PASSWORD_SALT")
NC_SECRET=$(db_get "NC_SECRET")
NC_VERSION_STORED=$(db_get "NC_VERSION")

# -----------------------------------------------------------------------------
# Fonction : générer le config.php complet depuis les variables connues.
# Appelée aussi bien au premier démarrage (après install) qu'aux suivants.
# Tous les paramètres sont ici — pas de fragments config-git/ additionnels
# pour éviter les conflits de merge Nextcloud.
# -----------------------------------------------------------------------------
write_config_php() {
    local instanceid="$1"
    local passwordsalt="$2"
    local secret="$3"
    local version="$4"

    cat > "$REAL_APP/config/config.php" << EOF
<?php
\$CONFIG = [
  // Identité de l'instance (générés à l'installation, persistés en BDD)
  'instanceid'   => '${instanceid}',
  'passwordsalt' => '${passwordsalt}',
  'secret'       => '${secret}',
  'installed'    => true,
  'version'      => '${version}',

  // Base de données PostgreSQL
  'dbtype'        => 'pgsql',
  'dbname'        => '${POSTGRESQL_ADDON_DB}',
  'dbhost'        => '${POSTGRESQL_ADDON_HOST}:${POSTGRESQL_ADDON_PORT}',
  'dbuser'        => '${POSTGRESQL_ADDON_USER}',
  'dbpassword'    => '${POSTGRESQL_ADDON_PASSWORD}',
  'dbtableprefix' => 'oc_',

  // Stockage objet S3 (Cellar)
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

  // Réseau & proxy Clever Cloud
  'overwriteprotocol'      => 'https',
  'overwrite.cli.url'      => 'https://${NEXTCLOUD_DOMAIN}',
  'overwritehost'          => '${NEXTCLOUD_DOMAIN}',
  'trusted_domains'        => ['${NEXTCLOUD_DOMAIN}'],
  'trusted_proxies'        => ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'],
  'forwarded_for_headers'  => ['HTTP_X_FORWARDED_FOR'],

  // Cache Redis
  'memcache.local'       => '\\OC\\Memcache\\Redis',
  'memcache.distributed' => '\\OC\\Memcache\\Redis',
  'memcache.locking'     => '\\OC\\Memcache\\Redis',
  'redis' => [
    'host'     => '${REDIS_HOST}',
    'port'     => (int) '${REDIS_PORT}',
    'password' => '${REDIS_PASSWORD}',
  ],

  // Données
  'datadirectory'              => '${REAL_APP}/data',
  'allow_local_remote_servers' => true,

  // Logs vers syslog (visible via clever logs)
  'log_type' => 'syslog',
  'loglevel'  => 2,

  // Divers
  'default_phone_region'    => 'FR',
  'maintenance_window_start' => 1,
];
EOF
    echo "[OK] config.php généré."
}

# -----------------------------------------------------------------------------
# Création du bucket S3 si inexistant (idempotent).
# rclone mkdir émet un PUT /<bucket> — opération no-op si le bucket existe déjà.
# Fait avant le démarrage d'Apache pour que l'objectstore soit prêt dès la
# première requête Nextcloud et éviter les 503 liés à l'init S3.
# -----------------------------------------------------------------------------
ensure_s3_bucket() {
    local RCLONE="$REAL_APP/bin/rclone"
    if [ ! -f "$RCLONE" ]; then
        echo "[WARN] rclone absent — bucket S3 non pré-créé."
        return
    fi
    echo "[INFO] Pré-création du bucket S3 $CELLAR_BUCKET_NAME (idempotent)..."
    "$RCLONE" mkdir \
        --config /dev/null \
        --s3-provider Other \
        --s3-access-key-id "$CELLAR_ADDON_KEY_ID" \
        --s3-secret-access-key "$CELLAR_ADDON_KEY_SECRET" \
        --s3-endpoint "https://$CELLAR_ADDON_HOST" \
        --s3-force-path-style \
        ":s3:${CELLAR_BUCKET_NAME}" 2>&1 \
        && echo "[OK] Bucket S3 $CELLAR_BUCKET_NAME prêt." \
        || echo "[WARN] rclone mkdir échoué — Nextcloud tentera autocreate au démarrage."
}

# -----------------------------------------------------------------------------
# PREMIER DÉMARRAGE vs REDÉMARRAGE
# -----------------------------------------------------------------------------
if [ -n "$NC_INSTANCE_ID" ] && [ -n "$NC_PASSWORD_SALT" ] && [ -n "$NC_SECRET" ]; then
    # -------------------------------------------------------------------------
    # REDÉMARRAGE — les secrets existent en BDD
    # -------------------------------------------------------------------------
    echo "[INFO] Secrets trouvés en BDD — redémarrage."

    # Détermination de la version courante
    NC_VERSION_CURRENT="$NC_VERSION_STORED"
    if [ -z "$NC_VERSION_CURRENT" ]; then
        # Fallback : lire depuis occ (ne nécessite pas config.php complet)
        NC_VERSION_CURRENT=$(php "$REAL_APP/occ" --version 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    fi
    [ -z "$NC_VERSION_CURRENT" ] && NC_VERSION_CURRENT="0.0.0"

    write_config_php "$NC_INSTANCE_ID" "$NC_PASSWORD_SALT" "$NC_SECRET" "$NC_VERSION_CURRENT"
    ensure_s3_bucket

    echo "[INFO] Vérification des migrations éventuelles..."
    php "$REAL_APP/occ" upgrade --no-interaction 2>/dev/null || true
    php "$REAL_APP/occ" db:add-missing-indices --no-interaction 2>/dev/null || true

else
    # -------------------------------------------------------------------------
    # PREMIER DÉMARRAGE — installation complète
    # -------------------------------------------------------------------------
    echo "[INFO] Aucun secret en BDD — installation complète."

    # occ maintenance:install génère son propre config.php minimal
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

    # Extraction des secrets depuis le config.php généré par occ
    extract_secret() {
        php -r "\$CONFIG=[]; include '${REAL_APP}/config/config.php'; echo \$CONFIG['$1'] ?? '';" 2>/dev/null || true
    }

    NC_INSTANCE_ID=$(extract_secret "instanceid")
    NC_PASSWORD_SALT=$(extract_secret "passwordsalt")
    NC_SECRET=$(extract_secret "secret")
    NC_VERSION_INSTALLED=$(extract_secret "version")

    # Validation stricte : si un secret est vide, on s'arrête avec un message clair
    if [ -z "$NC_INSTANCE_ID" ] || [ -z "$NC_PASSWORD_SALT" ] || [ -z "$NC_SECRET" ]; then
        echo "[ERR] Impossible d'extraire les secrets depuis config.php."
        echo "[ERR] Contenu du config.php généré :"
        cat "$REAL_APP/config/config.php" || true
        exit 1
    fi

    echo "[INFO] Persistance des secrets en BDD..."
    db_set "NC_INSTANCE_ID"   "$NC_INSTANCE_ID"
    db_set "NC_PASSWORD_SALT" "$NC_PASSWORD_SALT"
    db_set "NC_SECRET"        "$NC_SECRET"
    db_set "NC_VERSION"       "$NC_VERSION_INSTALLED"

    # Réécriture du config.php complet (remplace le minimal généré par occ)
    write_config_php "$NC_INSTANCE_ID" "$NC_PASSWORD_SALT" "$NC_SECRET" "$NC_VERSION_INSTALLED"
    ensure_s3_bucket

    echo "[INFO] Post-installation : indices, réparation..."
    php "$REAL_APP/occ" db:add-missing-indices --no-interaction 2>/dev/null || true
    php "$REAL_APP/occ" maintenance:repair --include-expensive --no-interaction 2>/dev/null || true

    echo "[OK] Installation Nextcloud terminée."
fi

# -----------------------------------------------------------------------------
# Paramètres idempotents (appliqués à chaque démarrage via occ pour s'assurer
# qu'ils sont bien en BDD Nextcloud, indépendamment du config.php)
# -----------------------------------------------------------------------------
php "$REAL_APP/occ" config:app:set core backgroundjobs_mode --value=webcron \
    --no-interaction 2>/dev/null || true
php "$REAL_APP/occ" maintenance:mode --off --no-interaction 2>/dev/null || true

echo "[OK] Nextcloud prêt : https://$NEXTCLOUD_DOMAIN"
