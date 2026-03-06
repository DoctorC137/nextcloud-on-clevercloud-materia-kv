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
REAL_APP=$(ls -d /home/bas/app_*/ 2>/dev/null | head -1 | sed 's|/$||')
if [ -z "$REAL_APP" ]; then
    echo "[ERR] Impossible de localiser le dossier de l'application." && exit 1
fi

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
# ÉTAPE 1 — Vérification directe que Cellar (S3) est joignable
# On tente un HEAD sur le bucket avant même de toucher WebDAV.
# Cellar renvoie 200/403/404 quand il répond ; toute réponse non-5xx est OK.
# Cela évite de bombarder Nextcloud avec des PUT alors que le backend S3
# n'est pas encore prêt (ce qui provoque des 503 côté Nextcloud).
# -----------------------------------------------------------------------------
echo "[INFO] Vérification directe de Cellar S3..."
S3_ENDPOINT="https://${CELLAR_ADDON_HOST}/${CELLAR_BUCKET_NAME}"
CELLAR_READY=0
for i in $(seq 1 24); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        -X HEAD "$S3_ENDPOINT" 2>/dev/null)
    # Toute réponse HTTP non-5xx indique que Cellar répond
    if [ -n "$HTTP" ] && [ "$HTTP" != "000" ] && [ "${HTTP:0:1}" != "5" ]; then
        echo "[OK] Cellar S3 joignable (HTTP $HTTP) après $i tentative(s)."
        CELLAR_READY=1
        break
    fi
    echo "[INFO] Attente Cellar S3... tentative $i/24 (HTTP $HTTP)"
    sleep 5
done

if [ "$CELLAR_READY" = "0" ]; then
    echo "[ERR] Timeout — Cellar S3 non joignable après 2 minutes. Abandon."
    exit 1
fi

# -----------------------------------------------------------------------------
# ÉTAPE 2 — Attente que Nextcloud serve correctement le WebDAV
# (l'objectstore autocreate peut prendre quelques secondes supplémentaires
# la toute première fois que Nextcloud l'initialise)
# On tente un PUT de test — 201 (créé) ou 204 (déjà là) signifient succès.
# -----------------------------------------------------------------------------
echo "[INFO] Attente de l'objectstore S3 via WebDAV Nextcloud..."
READY=0
for i in $(seq 1 24); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "$NC_AUTH" \
        -H "$NC_HOST_HEADER" \
        -X PUT --data-binary "ready" \
        --max-time 15 \
        "$NC_LOCAL/.skeleton_check" 2>/dev/null)
    if [ "$HTTP" = "201" ] || [ "$HTTP" = "204" ]; then
        curl -s -X DELETE -u "$NC_AUTH" -H "$NC_HOST_HEADER" \
            "$NC_LOCAL/.skeleton_check" -o /dev/null --max-time 10 2>/dev/null || true
        READY=1
        echo "[OK] ObjectStore prêt après $i tentative(s)."
        break
    fi
    echo "[INFO] Attente WebDAV... tentative $i/24 (HTTP $HTTP)"
    sleep 5
done

if [ "$READY" = "0" ]; then
    echo "[ERR] Timeout — WebDAV Nextcloud non fonctionnel après 2 minutes."
    echo "[ERR] Vérifiez les logs Nextcloud pour des erreurs S3/objectstore."
    exit 1
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
