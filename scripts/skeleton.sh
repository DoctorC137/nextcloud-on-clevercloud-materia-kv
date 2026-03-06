#!/bin/bash
# =============================================================================
# skeleton.sh — CC_RUN_SUCCEEDED_HOOK
# Uploads skeleton via WebDAV. Stateless: uses PostgreSQL to track status.
# =============================================================================
set -e

db_query() {
    PGPASSWORD="$POSTGRESQL_ADDON_PASSWORD" psql -h "$POSTGRESQL_ADDON_HOST" -p "$POSTGRESQL_ADDON_PORT" -U "$POSTGRESQL_ADDON_USER" -d "$POSTGRESQL_ADDON_DB" -tAc "$1" 2>/dev/null || true
}

NC_SKELETON_UPLOADED=$(db_query "SELECT value FROM cc_nextcloud_secrets WHERE key = 'NC_SKELETON_UPLOADED';")
if[ "$NC_SKELETON_UPLOADED" = "1" ]; then
    echo "[INFO] Skeleton déjà uploadé (détecté via BDD), rien à faire."
    exit 0
fi

REAL_APP=$(ls -d /home/bas/app_*/ 2>/dev/null | head -1 | sed 's|/$||')
SKELETON_DIR="$REAL_APP/core/skeleton"
NC_PORT="${PORT:-8080}"
NC_LOCAL="http://localhost:$NC_PORT/remote.php/dav/files/$NEXTCLOUD_ADMIN_USER"
NC_AUTH="$NEXTCLOUD_ADMIN_USER:$NEXTCLOUD_ADMIN_PASSWORD"
NC_HOST_HEADER="Host: $NEXTCLOUD_DOMAIN"

echo "[INFO] Attente de l'objectstore S3 pour WebDAV..."
READY=0
for i in $(seq 1 60); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$NC_AUTH" -H "$NC_HOST_HEADER" -X PUT --data-binary "ready" --max-time 10 "$NC_LOCAL/.skeleton_check" 2>/dev/null)
    if[ "$HTTP" = "201" ] || [ "$HTTP" = "204" ]; then
        curl -s -X DELETE -u "$NC_AUTH" -H "$NC_HOST_HEADER" "$NC_LOCAL/.skeleton_check" -o /dev/null --max-time 10 2>/dev/null || true
        READY=1
        echo "[OK] ObjectStore prêt."
        break
    fi
    sleep 5
done
[ "$READY" = "0" ] && echo "[ERR] Timeout S3." && exit 1

echo "[INFO] Upload du skeleton Nextcloud..."
while IFS= read -r d; do
    DIRNAME=$(basename "$d")
    ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$DIRNAME")
    curl -s -o /dev/null -X MKCOL -u "$NC_AUTH" -H "$NC_HOST_HEADER" --max-time 30 "$NC_LOCAL/$ENCODED" 2>/dev/null || true
done < <(find "$SKELETON_DIR" -mindepth 1 -maxdepth 1 -type d)

while IFS= read -r f; do
    REL="${f#$SKELETON_DIR/}"
    ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$REL")
    curl -s -o /dev/null -X PUT -u "$NC_AUTH" -H "$NC_HOST_HEADER" --max-time 120 "$NC_LOCAL/$ENCODED" --data-binary "@$f" 2>/dev/null || true
done < <(find "$SKELETON_DIR" -type f)

db_query "INSERT INTO cc_nextcloud_secrets (key, value) VALUES ('NC_SKELETON_UPLOADED', '1') ON CONFLICT (key) DO UPDATE SET value = '1';"
echo "[OK] Skeleton uploadé et état persisté en BDD."