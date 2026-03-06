#!/bin/bash
# =============================================================================
# clever-deploy.sh — Déploiement automatisé Nextcloud sur Clever Cloud
# =============================================================================

set -e

# Couleurs
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${BLUE}  ℹ  $1${NC}"; }
success() { echo -e "${GREEN}  ✓  $1${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠  $1${NC}"; }
error()   { echo -e "${RED}  ✗  $1${NC}"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}▶ $1${NC}\n"; }

ask() {
    echo -e "${CYAN}  ?  $1${NC}"
    echo -ne "${BOLD}      → ${NC}"
}

# Affiche un menu de sélection avec highlight sur le défaut
menu() {
    local title="$1"; shift
    local default_idx="$1"; shift
    local options=("$@")
    echo -e "${CYAN}  ?  $title${NC}"
    for i in "${!options[@]}"; do
        local num=$((i + 1))
        if [ "$i" -eq "$((default_idx - 1))" ]; then
            echo -e "      ${BOLD}${GREEN}$num) ${options[$i]} ★ conseillé${NC}"
        else
            echo -e "      ${DIM}$num) ${options[$i]}${NC}"
        fi
    done
    echo -ne "${BOLD}      → ${NC}"
}

extract_env() {
    echo "$2" | grep -E "^(export )?$1=" | sed -E "s/^(export )?$1=//" \
        | tr -d '"' | tr -d "'" | tr -d ' ' | tr -d $'\r' | tr -d ';'
}

# -----------------------------------------------------------------------------
# Nettoyage automatique en cas d'erreur
# -----------------------------------------------------------------------------
cleanup_on_error() {
    echo ""
    warn "Erreur détectée — nettoyage en cours..."
    [ -n "$CELLAR_ADDON_NAME" ] && clever addon delete "$CELLAR_ADDON_NAME" --yes 2>/dev/null || true
    [ -n "$FS_ADDON_NAME" ]     && clever addon delete "$FS_ADDON_NAME"     --yes 2>/dev/null || true
    [ -n "$REDIS_ADDON_NAME" ]  && clever addon delete "$REDIS_ADDON_NAME"  --yes 2>/dev/null || true
    [ -n "$PG_ADDON_NAME" ]     && clever addon delete "$PG_ADDON_NAME"     --yes 2>/dev/null || true
    [ -n "$APP_NAME" ]          && clever delete --app "$APP_NAME" --yes 2>/dev/null || true
    git remote remove clever 2>/dev/null || true
    rm -f .clever.json
    warn "Nettoyage terminé."
}
trap cleanup_on_error ERR

# =============================================================================
# PRÉREQUIS
# =============================================================================
echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║     Nextcloud — Déploiement Clever Cloud  ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

section "Vérification des prérequis"
command -v clever >/dev/null 2>&1 || error "clever-tools non installé : npm install -g clever-tools"
command -v git    >/dev/null 2>&1 || error "git non installé."
clever profile >/dev/null 2>&1    || error "Non connecté. Lancez : clever login"
git rev-parse --git-dir >/dev/null 2>&1 || error "Lancez ce script depuis la racine du repo git."
success "Prérequis OK."

# =============================================================================
# CONFIGURATION GÉNÉRALE
# =============================================================================
section "Configuration générale"

ask "Nom de l'application [défaut : nextcloud] :"
read -r APP_NAME
APP_NAME="${APP_NAME:-nextcloud}"
ALIAS="$APP_NAME"

echo ""
ask "ID organisation Clever Cloud (Entrée = compte personnel) :"
read -r ORG_INPUT
if [ -n "$ORG_INPUT" ]; then
    ORG_FLAG="--org $ORG_INPUT"
    info "Organisation : $ORG_INPUT"
else
    ORG_FLAG=""
    info "Compte personnel sélectionné."
fi

echo ""
ask "Domaine public (Entrée = domaine cleverapps.io automatique) :"
read -r NEXTCLOUD_DOMAIN
DOMAIN_AUTO=false
[ -z "$NEXTCLOUD_DOMAIN" ] && DOMAIN_AUTO=true && info "Domaine automatique cleverapps.io."

# Région
echo ""
REGIONS=(
    "Paris          (par)  — Europe, France"
    "Roubaix        (rbx)  — Europe, France"
    "Scaleway       (scw)  — Europe, France"
    "Londres        (ldn)  — Europe, Royaume-Uni"
    "Warsaw         (wsw)  — Europe, Pologne"
    "Montréal       (mtl)  — Amérique du Nord"
    "Singapour      (sgp)  — Asie-Pacifique"
    "Sydney         (syd)  — Asie-Pacifique"
)
REGION_CODES=("par" "rbx" "scw" "ldn" "wsw" "mtl" "sgp" "syd")
menu "Région de déploiement :" 1 "${REGIONS[@]}"
read -r RC
RC="${RC:-1}"
REGION="${REGION_CODES[$((RC - 1))]:-par}"
info "Région : $REGION"

# =============================================================================
# DIMENSIONNEMENT — Application PHP
# =============================================================================
section "Dimensionnement — Application PHP"

PHP_PLANS=(
    "nano  —  256 MB RAM, 0.5 vCPU   (test / dev)"
    "XS    —  512 MB RAM, 1 vCPU     (petite équipe)"
    "S     —  1 GB RAM,   2 vCPUs    (usage standard)"
    "M     —  2 GB RAM,   4 vCPUs    (usage intensif)"
)
PHP_PLAN_CODES=("nano" "XS" "S" "M")
menu "Plan de l'application PHP :" 3 "${PHP_PLANS[@]}"
read -r PC
PC="${PC:-3}"
PHP_PLAN="${PHP_PLAN_CODES[$((PC - 1))]:-S}"
info "Plan PHP : $PHP_PLAN"

# =============================================================================
# DIMENSIONNEMENT — PostgreSQL
# =============================================================================
section "Dimensionnement — Base de données PostgreSQL"

PG_PLANS=(
    "xxs_sml  —  1 vCPU,  512 MB RAM,  1 GB  BDD  (petite équipe)"
    "xs_sml   —  1 vCPU,  1 GB RAM,    5 GB  BDD  (usage standard)"
    "s_sml    —  2 vCPUs, 2 GB RAM,   10 GB  BDD  (usage intensif)"
    "m_sml    —  4 vCPUs, 4 GB RAM,   20 GB  BDD  (grande organisation)"
)
PG_PLAN_CODES=("xxs_sml" "xs_sml" "s_sml" "m_sml")
menu "Plan PostgreSQL :" 2 "${PG_PLANS[@]}"
read -r PGC
PGC="${PGC:-2}"
PG_PLAN="${PG_PLAN_CODES[$((PGC - 1))]:-xs_sml}"
info "Plan PostgreSQL : $PG_PLAN"

# Version PostgreSQL
PG_VERSIONS=(
    "16  —  recommandée par Nextcloud (stable, éprouvée)"
    "17  —  dernière version (fournie par défaut par Clever Cloud)"
    "15  —  version antérieure"
)
PG_VERSION_CODES=("16" "17" "15")
menu "Version PostgreSQL :" 1 "${PG_VERSIONS[@]}"
read -r PGV
PGV="${PGV:-1}"
PG_VERSION="${PG_VERSION_CODES[$((PGV - 1))]:-16}"
info "Version PostgreSQL : $PG_VERSION"

# =============================================================================
# DIMENSIONNEMENT — Redis
# =============================================================================
section "Dimensionnement — Cache Redis"

REDIS_PLANS=(
    "s_mono   —  1 vCPU, 128 MB  (petite équipe)"
    "m_mono   —  1 vCPU, 256 MB  (usage standard)"
    "l_mono   —  1 vCPU, 512 MB  (usage intensif)"
    "xl_mono  —  1 vCPU, 1 GB    (grande organisation)"
)
REDIS_PLAN_CODES=("s_mono" "m_mono" "l_mono" "xl_mono")
menu "Plan Redis :" 2 "${REDIS_PLANS[@]}"
read -r REC
REC="${REC:-2}"
REDIS_PLAN="${REDIS_PLAN_CODES[$((REC - 1))]:-m_mono}"
info "Plan Redis : $REDIS_PLAN"

# =============================================================================
# COMPTE ADMINISTRATEUR
# =============================================================================
section "Compte administrateur Nextcloud"

ask "Nom d'utilisateur admin [défaut : admin] :"
read -r NEXTCLOUD_ADMIN_USER
NEXTCLOUD_ADMIN_USER="${NEXTCLOUD_ADMIN_USER:-admin}"

echo ""
ask "Mot de passe admin :"
read -s -r NEXTCLOUD_ADMIN_PASSWORD
echo ""
[ -z "$NEXTCLOUD_ADMIN_PASSWORD" ] && error "Mot de passe obligatoire."

ask "Confirmez le mot de passe :"
read -s -r NC_PASS_CONFIRM
echo ""
[ "$NEXTCLOUD_ADMIN_PASSWORD" != "$NC_PASS_CONFIRM" ] && error "Mots de passe différents."

# =============================================================================
# RÉSUMÉ
# =============================================================================
section "Résumé"
echo -e "  ${DIM}Application${NC}  ${BOLD}$APP_NAME${NC} — région ${BOLD}$REGION${NC}"
echo -e "  ${DIM}Domaine     ${NC}  ${BOLD}${NEXTCLOUD_DOMAIN:-cleverapps.io automatique}${NC}"
echo -e "  ${DIM}PHP         ${NC}  ${BOLD}$PHP_PLAN${NC}"
echo -e "  ${DIM}PostgreSQL  ${NC}  ${BOLD}$PG_PLAN${NC} — version ${BOLD}$PG_VERSION${NC}"
echo -e "  ${DIM}Redis       ${NC}  ${BOLD}$REDIS_PLAN${NC}"
echo -e "  ${DIM}Admin       ${NC}  ${BOLD}$NEXTCLOUD_ADMIN_USER${NC}"
echo ""
ask "Confirmer le déploiement ? (o/N) :"
read -r CONFIRM
[[ "$CONFIRM" =~ ^[oOyY]$ ]] || { trap - ERR; warn "Annulé."; exit 0; }

# =============================================================================
# CRÉATION DES RESSOURCES
# =============================================================================
section "Création de l'application PHP"
clever create --type php --region "$REGION" $ORG_FLAG --alias "$ALIAS" "$APP_NAME"

if [ "$DOMAIN_AUTO" = "true" ]; then
    NEXTCLOUD_DOMAIN=$(clever domain --alias "$ALIAS" 2>/dev/null \
        | grep 'cleverapps.io' | awk '{print $1}' | tr -d '/' | head -n1)
    [ -z "$NEXTCLOUD_DOMAIN" ] && NEXTCLOUD_DOMAIN="${APP_NAME}.cleverapps.io"
fi

clever env set --alias "$ALIAS" CC_PHP_VERSION      8.2
clever env set --alias "$ALIAS" CC_PHP_MEMORY_LIMIT 512M
clever env set --alias "$ALIAS" CC_PHP_EXTENSIONS   apcu
clever env set --alias "$ALIAS" CC_WEBROOT          /
clever env set --alias "$ALIAS" CC_POST_BUILD_HOOK "scripts/install.sh"
clever env set --alias "$ALIAS" CC_PRE_RUN_HOOK    "scripts/run.sh"
clever env set --alias "$ALIAS" CC_RUN_SUCCEEDED_HOOK "scripts/skeleton.sh"
success "Application PHP créée — domaine : $NEXTCLOUD_DOMAIN"

section "Création des addons"

# PostgreSQL
PG_ADDON_NAME="${APP_NAME}-pg"
clever addon create postgresql-addon --plan "$PG_PLAN" --region "$REGION" \
    --addon-version "$PG_VERSION" \
    $ORG_FLAG --link "$ALIAS" "$PG_ADDON_NAME" --yes >/dev/null 2>&1
success "PostgreSQL créé ($PG_PLAN, version $PG_VERSION)"

# Redis
REDIS_ADDON_NAME="${APP_NAME}-redis"
REDIS_OUT=$(clever addon create redis-addon --plan "$REDIS_PLAN" --region "$REGION" \
    $ORG_FLAG --link "$ALIAS" "$REDIS_ADDON_NAME" --yes 2>&1)
REDIS_ADDON_ID=$(echo "$REDIS_OUT" | grep "^ID:" | awk '{print $2}' | head -n1)
[ -z "$REDIS_ADDON_ID" ] && error "Impossible d'extraire l'ID Redis."
REDIS_ENV=$(clever addon env "$REDIS_ADDON_ID" $ORG_FLAG --format shell 2>&1)
REDIS_HOST_VAL=$(extract_env "REDIS_HOST"     "$REDIS_ENV")
REDIS_PORT_VAL=$(extract_env "REDIS_PORT"     "$REDIS_ENV" | tr -dc '0-9')
REDIS_PASS_VAL=$(extract_env "REDIS_PASSWORD" "$REDIS_ENV")
[ -z "$REDIS_HOST_VAL" ] && error "REDIS_HOST introuvable."
clever env set --alias "$ALIAS" REDIS_HOST     "$REDIS_HOST_VAL"
clever env set --alias "$ALIAS" REDIS_PORT     "$REDIS_PORT_VAL"
clever env set --alias "$ALIAS" REDIS_PASSWORD "$REDIS_PASS_VAL"
success "Redis créé ($REDIS_PLAN)"

# Cellar S3
CELLAR_ADDON_NAME="${APP_NAME}-cellar"
CELLAR_OUT=$(clever addon create cellar-addon --plan s --region "$REGION" \
    $ORG_FLAG --link "$ALIAS" "$CELLAR_ADDON_NAME" --yes 2>&1)
CELLAR_ADDON_ID=$(echo "$CELLAR_OUT" | grep "^ID:" | awk '{print $2}' | head -n1)
[ -z "$CELLAR_ADDON_ID" ] && error "Impossible d'extraire l'ID Cellar."
CELLAR_BUCKET_SUFFIX=$(echo "$CELLAR_ADDON_ID" | sed "s/addon_//" | cut -c1-8)
CELLAR_BUCKET_NAME="${APP_NAME}-files-${CELLAR_BUCKET_SUFFIX}"
CELLAR_ENV=$(clever addon env "$CELLAR_ADDON_ID" $ORG_FLAG --format shell 2>&1)
CELLAR_KEY=$(extract_env    "CELLAR_ADDON_KEY_ID"     "$CELLAR_ENV")
CELLAR_SECRET=$(extract_env "CELLAR_ADDON_KEY_SECRET" "$CELLAR_ENV")
CELLAR_HOST=$(extract_env   "CELLAR_ADDON_HOST"       "$CELLAR_ENV")
[ -z "$CELLAR_KEY" ] && error "CELLAR_ADDON_KEY_ID introuvable."
clever env set --alias "$ALIAS" CELLAR_ADDON_KEY_ID     "$CELLAR_KEY"
clever env set --alias "$ALIAS" CELLAR_ADDON_KEY_SECRET "$CELLAR_SECRET"
clever env set --alias "$ALIAS" CELLAR_ADDON_HOST       "$CELLAR_HOST"
clever env set --alias "$ALIAS" CELLAR_BUCKET_NAME      "$CELLAR_BUCKET_NAME"
success "Cellar S3 créé (stockage fichiers)"

# Variables Nextcloud
clever env set --alias "$ALIAS" NEXTCLOUD_DOMAIN         "$NEXTCLOUD_DOMAIN"
clever env set --alias "$ALIAS" NEXTCLOUD_ADMIN_USER     "$NEXTCLOUD_ADMIN_USER"
clever env set --alias "$ALIAS" NEXTCLOUD_ADMIN_PASSWORD "$NEXTCLOUD_ADMIN_PASSWORD"
success "Variables Nextcloud configurées."

# Domaine personnalisé
if [ "$DOMAIN_AUTO" = "false" ] && [ -n "$NEXTCLOUD_DOMAIN" ]; then
    clever domain add --alias "$ALIAS" "$NEXTCLOUD_DOMAIN"
    success "Domaine $NEXTCLOUD_DOMAIN ajouté."
    warn "DNS : créez un CNAME $NEXTCLOUD_DOMAIN → domain.clever-cloud.com"
fi

# =============================================================================
# DÉPLOIEMENT
# =============================================================================
section "Déploiement"
git update-index --chmod=+x scripts/run.sh scripts/install.sh 2>/dev/null || true
info "Envoi du code source..."
clever deploy --alias "$ALIAS" --force

trap - ERR

# =============================================================================
# SUCCÈS
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║            Déploiement réussi !           ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}URL    ${NC}  ${BOLD}${GREEN}https://$NEXTCLOUD_DOMAIN${NC}"
echo -e "  ${DIM}Admin  ${NC}  ${BOLD}$NEXTCLOUD_ADMIN_USER${NC}"
echo -e "  ${DIM}Logs   ${NC}  clever logs --alias $ALIAS"
echo ""
warn "Premier démarrage : 2 à 5 minutes (installation Nextcloud)."
echo ""
