#!/bin/bash
# =============================================================================
# install.sh — CC_POST_BUILD_HOOK
# Télécharge et extrait Nextcloud. Gère les upgrades majeurs par étapes.
# Lit la version installée depuis PostgreSQL (table cc_nextcloud_secrets).
# =============================================================================
set -e

major_version() { echo "$1" | cut -d. -f1; }

latest_in_major() {
    local major="$1"
    curl -s "https://download.nextcloud.com/server/releases/" \
        | grep -oP "nextcloud-${major}\.[0-9]+\.[0-9]+\.zip" \
        | grep -v "beta\|rc\|RC" \
        | sed 's/nextcloud-//;s/\.zip//' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1
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

# -----------------------------------------------------------------------------
# rclone — téléchargé une fois, mis en cache via le build cache Clever Cloud
# -----------------------------------------------------------------------------
RCLONE_BIN="$(pwd)/bin/rclone"
if [ ! -f "$RCLONE_BIN" ]; then
    echo "[INFO] Téléchargement de rclone..."
    mkdir -p "$(pwd)/bin"
    curl -fsSL "https://downloads.rclone.org/rclone-current-linux-amd64.zip" -o /tmp/rclone.zip
    unzip -q /tmp/rclone.zip -d /tmp/rclone_extract
    mv /tmp/rclone_extract/rclone-*/rclone "$RCLONE_BIN"
    chmod +x "$RCLONE_BIN"
    rm -rf /tmp/rclone.zip /tmp/rclone_extract
    echo "[OK] rclone installé."
else
    echo "[INFO] rclone déjà présent dans le cache."
fi

# -----------------------------------------------------------------------------
# Version cible
# -----------------------------------------------------------------------------
if [ -z "$NEXTCLOUD_VERSION" ]; then
    echo "[INFO] Récupération de la dernière version stable..."
    NC_TARGET=$(curl -s "https://api.github.com/repos/nextcloud/server/releases/latest" \
        | grep '"tag_name"' \
        | sed 's/.*"v\([^"]*\)".*/\1/')
    [ -z "$NC_TARGET" ] && NC_TARGET="30.0.0"
else
    NC_TARGET="$NEXTCLOUD_VERSION"
fi
echo "[INFO] Version cible : $NC_TARGET"

# -----------------------------------------------------------------------------
# Lecture de la version installée depuis PostgreSQL.
# La table peut ne pas exister encore (premier déploiement) — c'est normal,
# psql retournera une erreur absorbée par || true, NC_CURRENT restera vide.
# -----------------------------------------------------------------------------
NC_CURRENT=""
if [ -n "$POSTGRESQL_ADDON_PASSWORD" ] && [ -n "$POSTGRESQL_ADDON_HOST" ]; then
    NC_CURRENT=$(PGPASSWORD="$POSTGRESQL_ADDON_PASSWORD" psql \
        -h "$POSTGRESQL_ADDON_HOST" \
        -p "$POSTGRESQL_ADDON_PORT" \
        -U "$POSTGRESQL_ADDON_USER" \
        -d "$POSTGRESQL_ADDON_DB" \
        -tAc "SELECT value FROM cc_nextcloud_secrets WHERE key = 'NC_VERSION';" \
        2>/dev/null || true)
    NC_CURRENT=$(echo "${NC_CURRENT}" | tr -d '[:space:]' | cut -d. -f1-3)
fi

# -----------------------------------------------------------------------------
# Décision d'installation / upgrade
# -----------------------------------------------------------------------------
if [ -z "$NC_CURRENT" ]; then
    echo "[INFO] Aucune installation détectée en BDD — installation directe."
    apply_version "$NC_TARGET"
else
    MAJOR_CURRENT=$(major_version "$NC_CURRENT")
    MAJOR_TARGET=$(major_version "$NC_TARGET")
    echo "[INFO] Version installée : $NC_CURRENT (majeur $MAJOR_CURRENT) → cible : $NC_TARGET (majeur $MAJOR_TARGET)"

    if [ "$MAJOR_CURRENT" -eq "$MAJOR_TARGET" ]; then
        echo "[INFO] Même version majeure, mise à jour directe."
        apply_version "$NC_TARGET"
    elif [ "$MAJOR_TARGET" -lt "$MAJOR_CURRENT" ]; then
        echo "[ERR] Downgrade interdit ($NC_CURRENT → $NC_TARGET)." && exit 1
    else
        # Upgrade par étapes : on monte major par major
        STEP=$MAJOR_CURRENT
        while [ "$STEP" -lt "$MAJOR_TARGET" ]; do
            NEXT=$((STEP + 1))
            STEP_VERSION=$(latest_in_major "$NEXT")
            if [ -z "$STEP_VERSION" ]; then
                echo "[ERR] Impossible de trouver la dernière version majeure $NEXT." && exit 1
            fi
            echo "[INFO] Étape intermédiaire : majeur $STEP → $STEP_VERSION"
            apply_version "$STEP_VERSION"
            STEP=$NEXT
        done
        echo "[INFO] Étape finale : $NC_TARGET"
        apply_version "$NC_TARGET"
    fi
fi

# -----------------------------------------------------------------------------
# S'assurer que tous les scripts sont exécutables après extraction
# -----------------------------------------------------------------------------
chmod +x scripts/run.sh scripts/install.sh scripts/skeleton.sh \
         scripts/cron.sh scripts/sync-apps.sh 2>/dev/null || true

echo "[OK] Nextcloud $NC_TARGET prêt pour le démarrage."
