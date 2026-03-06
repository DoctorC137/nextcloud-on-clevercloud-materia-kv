#!/bin/bash
# =============================================================================
# sync-apps.sh — Sync bidirectionnel custom_apps/ ↔ Cellar S3
# Usage :
#   sync-apps.sh pull   — télécharge custom_apps/ depuis S3 (boot)
#   sync-apps.sh push   — uploade custom_apps/ vers S3 (post install/remove app)
#
# Préfixe S3 : custom_apps/ dans le bucket principal (CELLAR_BUCKET_NAME)
# Utilise rclone avec configuration inline (pas de fichier de config)
# =============================================================================

set -e

REAL_APP=$(cd "$(dirname "$0")/.." && pwd)
RCLONE="$REAL_APP/bin/rclone"
DIRECTION="${1:-pull}"

# Vérifications
[ ! -f "$RCLONE" ] && echo "[ERR] rclone introuvable : $RCLONE" && exit 1
[ -z "$CELLAR_ADDON_KEY_ID" ]     && echo "[ERR] CELLAR_ADDON_KEY_ID manquant"     && exit 1
[ -z "$CELLAR_ADDON_KEY_SECRET" ] && echo "[ERR] CELLAR_ADDON_KEY_SECRET manquant" && exit 1
[ -z "$CELLAR_ADDON_HOST" ]       && echo "[ERR] CELLAR_ADDON_HOST manquant"       && exit 1
[ -z "$CELLAR_BUCKET_NAME" ]      && echo "[ERR] CELLAR_BUCKET_NAME manquant"      && exit 1

# Options rclone communes — configuration inline sans fichier
RCLONE_OPTS=(
    --config /dev/null
    --s3-provider Other
    --s3-access-key-id "$CELLAR_ADDON_KEY_ID"
    --s3-secret-access-key "$CELLAR_ADDON_KEY_SECRET"
    --s3-endpoint "https://$CELLAR_ADDON_HOST"
    --s3-force-path-style
    --transfers 4
    --retries 3
    --log-level INFO
)

S3_PATH=":s3:${CELLAR_BUCKET_NAME}/custom_apps"
LOCAL_PATH="$REAL_APP/custom_apps"

mkdir -p "$LOCAL_PATH"

case "$DIRECTION" in
    pull)
        echo "[INFO] sync-apps: pull S3 → local..."
        "$RCLONE" sync "$S3_PATH" "$LOCAL_PATH" "${RCLONE_OPTS[@]}" \
            && echo "[OK] custom_apps/ synchronisé depuis S3." \
            || echo "[WARN] sync-apps pull échoué — custom_apps/ local utilisé tel quel."
        ;;
    push)
        echo "[INFO] sync-apps: push local → S3..."
        "$RCLONE" sync "$LOCAL_PATH" "$S3_PATH" "${RCLONE_OPTS[@]}" \
            && echo "[OK] custom_apps/ uploadé vers S3." \
            || echo "[WARN] sync-apps push échoué — réessayer manuellement."
        ;;
    *)
        echo "[ERR] Usage : sync-apps.sh [pull|push]"
        exit 1
        ;;
esac
