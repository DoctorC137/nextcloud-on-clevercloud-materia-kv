#!/bin/bash
# =============================================================================
# skeleton.sh — CC_RUN_SUCCEEDED_HOOK
# Upload les fichiers du skeleton Nextcloud via WebDAV au premier démarrage.
# Stateless : utilise la table PostgreSQL cc_nextcloud_secrets pour savoir
# si l'upload a déjà été effectué (clé NC_SKELETON_UPLOADED = 1).
# =============================================================================

# Pas de set -e ici : on gère les erreurs manuellement pour éviter que
# des échecs WebDAV bénins (fichier déjà existant) n'arrêtent le script.

# -----------------------------------------------------------------------------
# Helper PostgreSQL — retourne "" en cas d'erreur (table absente, etc.)
# -----------------------------------------------------------------------------
db_query() {
    PGPASSWORD="$POSTGRESQL_ADDON_PASSWORD" psql \
        -h "$POSTGRESQL_ADDON_HOST" \
        -p "$POSTGRESQL_ADDON_PORT" \
        -U "$POSTGRESQL_ADDON_USER" \
        -d "$POSTGRESQL_ADDON_DB" \
        -tAc "$1" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Vérification : skeleton déjà uploadé ?
# Si la table n'existe pas encore, db_query retourne "" → on continue.
# -----------------------------------------------------------------------------
NC_SKELETON_UPLOADED=$(db_query \
    "SELECT value FROM cc_nextcloud_secrets WHERE key = 'NC_SKELETON_UPLOADED';" \
    | tr -d '[:space:]')

if [ "$NC_SKELETON_UPLOADED" = "1" ]; then
    echo "[INFO] Skeleton déjà uploadé (BDD), rien à faire."
    exit 0
fi

# -----------------------------------------------------------------------------
# Paramètres WebDAV
# -----------------------------------------------------------------------------
SKELETON_DIR="$REAL_APP/core/skeleton"
if [ ! -d "$SKELETON_DIR" ]; then
    echo "[WARN] Dossier skeleton introuvable ($SKELETON_DIR), rien à uploader."
    exit 0
fi

NC_PORT="${PORT:-8080}"
NC_LOCAL="http://localhost:$NC_PORT/remote.php/dav/files/$NEXTCLOUD_ADMIN_USER"
NC_AUTH="$NEXTCLOUD_ADMIN_USER:$NEXTCLOUD_ADMIN_PASSWORD"
NC_HOST_HEADER="Host: $NEXTCLOUD_DOMAIN"

# -----------------------------------------------------------------------------
# Helper : réactive memcache.locking dans config.php via occ
# Appelé en fin de script (succès ou échec) pour s'assurer que le locking
# est toujours réactivé, même si skeleton.sh échoue.
# -----------------------------------------------------------------------------
REAL_APP=$(ls -d /home/bas/app_*/ 2>/dev/null | head -1 | sed 's|/$||')
if [ -z "$REAL_APP" ]; then
    echo "[ERR] Impossible de localiser le dossier de l'application." && exit 1
fi

enable_locking() {
    echo "[INFO] Réactivation de memcache.locking dans config.php..."
    php "$REAL_APP/occ" config:system:set memcache.locking \
        --value='\OC\Memcache\Redis' --type=string --no-interaction 2>/dev/null \
        && echo "[OK] memcache.locking réactivé." \
        || echo "[WARN] Impossible de réactiver memcache.locking via occ."
}
trap enable_locking EXIT

# -----------------------------------------------------------------------------
# ÉTAPE 1 — Vérification directe que Cellar répond (HEAD sur le bucket)
# Un 404 est normal si le bucket n'existe pas encore.
# Un 5xx ou HTTP 000 indique que Cellar lui-même est HS.
# -----------------------------------------------------------------------------
echo "[INFO] Vérification directe de Cellar S3..."
S3_ENDPOINT="https://${CELLAR_ADDON_HOST}/${CELLAR_BUCKET_NAME}"
CELLAR_READY=0
for i in $(seq 1 12); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        -X HEAD "$S3_ENDPOINT" 2>/dev/null)
    if [ -n "$HTTP" ] && [ "$HTTP" != "000" ] && [ "${HTTP:0:1}" != "5" ]; then
        echo "[OK] Cellar S3 joignable (HTTP $HTTP) après $i tentative(s)."
        if [ "$HTTP" = "404" ]; then
            echo "[WARN] Le bucket '$CELLAR_BUCKET_NAME' n'existe pas (HTTP 404)."
            echo "[WARN] Créez-le manuellement dans la console Clever Cloud"
            echo "[WARN] (Addon Cellar → Buckets → Add bucket → '$CELLAR_BUCKET_NAME')."
            echo "[WARN] Le skeleton ne sera pas uploadé ce démarrage."
            exit 0
        fi
        CELLAR_READY=1
        break
    fi
    echo "[INFO] Attente Cellar... tentative $i/12 (HTTP $HTTP)"
    sleep 5
done

if [ "$CELLAR_READY" = "0" ]; then
    echo "[ERR] Cellar S3 injoignable après 1 minute — skeleton ignoré ce démarrage."
    exit 0
fi

# -----------------------------------------------------------------------------
# ÉTAPE 2 — Attente que le WebDAV Nextcloud soit fonctionnel
# (autocreate peut prendre quelques secondes la toute première fois)
# -----------------------------------------------------------------------------
echo "[INFO] Attente de l'objectstore S3 via WebDAV Nextcloud..."
READY=0
for i in $(seq 1 24); do
    BODY=$(curl -s -w "\n%{http_code}" \
        -u "$NC_AUTH" \
        -H "$NC_HOST_HEADER" \
        -X PUT --data-binary "ready" \
        --max-time 15 \
        "$NC_LOCAL/.skeleton_check" 2>/dev/null)
    HTTP=$(echo "$BODY" | tail -1)
    if [ "$HTTP" = "201" ] || [ "$HTTP" = "204" ]; then
        curl -s -X DELETE -u "$NC_AUTH" -H "$NC_HOST_HEADER" \
            "$NC_LOCAL/.skeleton_check" -o /dev/null --max-time 10 2>/dev/null || true
        READY=1
        echo "[OK] ObjectStore prêt après $i tentative(s)."
        break
    fi
    # Diagnostiquer : status.php sans auth + body WebDAV
    STATUS=$(curl -s --max-time 5 "http://localhost:${PORT:-8080}/status.php" 2>/dev/null | cut -c1-200)
    BODY_PREVIEW=$(echo "$BODY" | head -3 | tr '\n' ' ' | cut -c1-120)
    echo "[INFO] Attente WebDAV... tentative $i/24 (HTTP $HTTP)"
    echo "[INFO]   status.php: $STATUS"
    echo "[INFO]   webdav body: $BODY_PREVIEW"
    sleep 5
done

if [ "$READY" = "0" ]; then
    echo "[ERR] Timeout — WebDAV Nextcloud non fonctionnel après 2 minutes."
    echo "[ERR] Skeleton ignoré ce démarrage (non bloquant)."
    exit 0
fi

# -----------------------------------------------------------------------------
# Upload des dossiers (MKCOL)
# -----------------------------------------------------------------------------
echo "[INFO] Upload du skeleton Nextcloud..."
UPLOAD_ERRORS=0

while IFS= read -r d; do
    DIRNAME=$(basename "$d")
    ENCODED=$(python3 -c \
        "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" \
        "$DIRNAME" 2>/dev/null)
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        -X MKCOL -u "$NC_AUTH" -H "$NC_HOST_HEADER" \
        --max-time 30 "$NC_LOCAL/$ENCODED" 2>/dev/null)
    # 201 = créé, 405 = existe déjà — les deux sont OK
    if [ "$HTTP" != "201" ] && [ "$HTTP" != "405" ]; then
        echo "[WARN] MKCOL $DIRNAME → HTTP $HTTP"
        UPLOAD_ERRORS=$((UPLOAD_ERRORS + 1))
    fi
done < <(find "$SKELETON_DIR" -mindepth 1 -maxdepth 1 -type d)

# -----------------------------------------------------------------------------
# Upload des fichiers (PUT)
# -----------------------------------------------------------------------------
while IFS= read -r f; do
    REL="${f#$SKELETON_DIR/}"
    ENCODED=$(python3 -c \
        "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" \
        "$REL" 2>/dev/null)
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT -u "$NC_AUTH" -H "$NC_HOST_HEADER" \
        --max-time 120 "$NC_LOCAL/$ENCODED" \
        --data-binary "@$f" 2>/dev/null)
    # 201 = créé, 204 = mis à jour — les deux sont OK
    if [ "$HTTP" != "201" ] && [ "$HTTP" != "204" ]; then
        echo "[WARN] PUT $REL → HTTP $HTTP"
        UPLOAD_ERRORS=$((UPLOAD_ERRORS + 1))
    fi
done < <(find "$SKELETON_DIR" -type f)

if [ "$UPLOAD_ERRORS" -gt 0 ]; then
    echo "[WARN] $UPLOAD_ERRORS fichier(s) n'ont pas pu être uploadés (non bloquant)."
fi

# -----------------------------------------------------------------------------
# Persistance en BDD — même si des erreurs mineures ont eu lieu on marque done
# pour éviter de relancer à chaque démarrage
# -----------------------------------------------------------------------------
db_query "INSERT INTO cc_nextcloud_secrets (key, value)
          VALUES ('NC_SKELETON_UPLOADED', '1')
          ON CONFLICT (key) DO UPDATE SET value = '1';"

echo "[OK] Skeleton uploadé et état persisté en BDD."
