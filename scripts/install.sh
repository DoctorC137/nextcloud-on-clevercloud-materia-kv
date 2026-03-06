#!/bin/bash
# =============================================================================
# install.sh — CC_POST_BUILD_HOOK
# =============================================================================
set -e

major_version() { echo "$1" | cut -d. -f1; }

latest_in_major() {
    local major="$1"
    curl -s "https://download.nextcloud.com/server/releases/" | grep -oP "nextcloud-${major}\.[0-9]+\.[0-9]+\.zip" | grep -v "beta\|rc\|RC" | sed 's/nextcloud-//;s/\.zip//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

apply_version() {
    local version="$1"
    echo "[INFO] Application de Nextcloud $version..."
    wget -q "https://download.nextcloud.com/server/releases/nextcloud-${version}.zip" -O nextcloud-dl.zip
    unzip -q nextcloud-dl.zip
    rm -rf nextcloud/config
    shopt -s dotglob
    cp -rf nextcloud/* .
    rm -rf nextcloud nextcloud-dl.zip
    echo "[OK] Nextcloud $version extrait."
}

RCLONE_BIN="$(pwd)/bin/rclone"
if[ ! -f "$RCLONE_BIN" ]; then
    echo "[INFO] Téléchargement de rclone..."
    mkdir -p "$(pwd)/bin"
    curl -fsSL "https://downloads.rclone.org/rclone-current-linux-amd64.zip" -o /tmp/rclone.zip
    unzip -q /tmp/rclone.zip -d /tmp/rclone_extract
    mv /tmp/rclone_extract/rclone-*/rclone "$RCLONE_BIN"
    chmod +x "$RCLONE_BIN"
    rm -rf /tmp/rclone.zip /tmp/rclone_extract
    echo "[OK] rclone installé."
fi

if[ -z "$NEXTCLOUD_VERSION" ]; then
    echo "[INFO] Récupération de la dernière version stable..."
    NC_TARGET=$(curl -s "https://api.github.com/repos/nextcloud/server/releases/latest" | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    [ -z "$NC_TARGET" ] && NC_TARGET="33.0.0"
else
    NC_TARGET="$NEXTCLOUD_VERSION"
fi

# Lecture de la version depuis la BDD PostgreSQL
NC_VERSION=$(PGPASSWORD="$POSTGRESQL_ADDON_PASSWORD" psql -h "$POSTGRESQL_ADDON_HOST" -p "$POSTGRESQL_ADDON_PORT" -U "$POSTGRESQL_ADDON_USER" -d "$POSTGRESQL_ADDON_DB" -tAc "SELECT value FROM cc_nextcloud_secrets WHERE key = 'NC_VERSION';" 2>/dev/null || true)
NC_CURRENT=$(echo "${NC_VERSION:-}" | cut -d. -f1-3)

if [ -z "$NC_CURRENT" ]; then
    echo "[INFO] Aucune installation détectée en BDD — installation directe."
    apply_version "$NC_TARGET"
else
    MAJOR_CURRENT=$(major_version "$NC_CURRENT")
    MAJOR_TARGET=$(major_version "$NC_TARGET")
    
    if [ "$MAJOR_CURRENT" -eq "$MAJOR_TARGET" ]; then
        apply_version "$NC_TARGET"
    elif[ "$MAJOR_TARGET" -lt "$MAJOR_CURRENT" ]; then
        echo "[ERR] Downgrade interdit." && exit 1
    else
        STEP=$MAJOR_CURRENT
        while [ "$STEP" -lt "$MAJOR_TARGET" ]; do
            NEXT=$((STEP + 1))
            STEP_VERSION=$(latest_in_major "$NEXT")
            echo "[INFO] Étape intermédiaire : → $STEP_VERSION"
            apply_version "$STEP_VERSION"
            STEP=$NEXT
        done
        apply_version "$NC_TARGET"
    fi
fi
echo "[OK] Nextcloud $NC_TARGET prêt pour le démarrage."
chmod +x scripts/run.sh scripts/install.sh scripts/skeleton.sh scripts/cron.sh scripts/sync-apps.sh 2>/dev/null || true