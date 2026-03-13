#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Fluxer Self-Host Setup
# Generates config files, obtains an SSL certificate, and starts the server.
# Run once on a fresh machine: bash setup.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}▸${RESET} $*"; }
success() { echo -e "${GREEN}✔${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
error()   { echo -e "${RED}✖${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}$*${RESET}"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    error "Required command '$1' not found. $2"
    exit 1
  fi
}

gen_secret() {
  # 64-character random hex string
  openssl rand -hex 32
}

gen_vapid_keys() {
  # Generates a VAPID key pair (P-256 curve) using Node.js and prints
  # "PUBLIC_KEY,PRIVATE_KEY" to stdout.
  # Returns 1 if Node.js is not available.
  if ! command -v node &>/dev/null; then return 1; fi
  node - <<'JS'
const crypto = require('crypto');
const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
// SPKI-encoded public key → strip 27-byte header → base64url
const pubDer  = publicKey.export({ type: 'spki', format: 'der' });
const pubB64  = pubDer.slice(27).toString('base64url');
// PKCS8-encoded private key → strip 36-byte header → base64url
const privDer = privateKey.export({ type: 'pkcs8', format: 'der' });
const privB64 = privDer.slice(36).toString('base64url');
process.stdout.write(pubB64 + ',' + privB64);
JS
}

prompt() {
  # Usage: prompt VAR_NAME "Question" "default_value"
  local varname="$1" question="$2" default="${3:-}"
  
  # If the variable is already set in the environment, use it and skip prompt
  if [[ -n "${!varname:-}" ]]; then
    info "Using ${varname} from environment: ${!varname}"
    return 0
  fi

  if [[ -n "$default" ]]; then
    echo -en "${CYAN}?${RESET} ${question} [${default}]: "
  else
    echo -en "${CYAN}?${RESET} ${question}: "
  fi
  read -r input
  if [[ -z "$input" && -n "$default" ]]; then
    printf -v "$varname" '%s' "$default"
  else
    printf -v "$varname" '%s' "$input"
  fi
}

prompt_yn() {
  # Usage: prompt_yn VAR_NAME "Question" default (default: y or n)
  # Returns 0 for yes, 1 for no
  local varname="$1" question="$2" default="${3:-y}"

  # If the variable is already set in the environment, use it and skip prompt
  if [[ -n "${!varname:-}" ]]; then
    info "Using ${varname} from environment: ${!varname}"
    [[ "${!varname}" =~ ^[Yy] ]]
    return $?
  fi

  local hint; [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
  echo -en "${CYAN}?${RESET} ${question} [${hint}]: "
  read -r ans
  [[ -z "$ans" ]] && ans="$default"
  
  # Set the variable for consistency with prompt()
  if [[ "$ans" =~ ^[Yy] ]]; then
    printf -v "$varname" "true"
    return 0
  else
    printf -v "$varname" "false"
    return 1
  fi
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
header "Checking prerequisites…"
require_cmd docker  "Install Docker: https://docs.docker.com/engine/install/"
require_cmd openssl "Install openssl (usually: apt install openssl)"

# docker compose v2 (plugin) or v1 (standalone)
if docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  error "Docker Compose not found. Install it: https://docs.docker.com/compose/install/"
  exit 1
fi

success "Docker and Docker Compose found."

# ── Re-run guard ──────────────────────────────────────────────────────────────
if [[ -f .env && -f config/config.json ]]; then
  warn "config/config.json and .env already exist."
  if ! prompt_yn SKIP_RERUN_CONFIRM "Re-run setup and overwrite them?" "n"; then
    info "Nothing changed. To start: ${COMPOSE} up -d"
    exit 0
  fi
fi

# ── Gather settings ───────────────────────────────────────────────────────────
header "Server configuration"

prompt DOMAIN        "Your server's domain name (e.g. chat.example.com)" ""
while [[ -z "$DOMAIN" ]]; do
  warn "Domain name is required."
  prompt DOMAIN "Your server's domain name" ""
done

prompt LE_EMAIL      "Email for Let's Encrypt notifications" ""
while [[ -z "$LE_EMAIL" ]]; do
  warn "Email is required for Let's Encrypt."
  prompt LE_EMAIL "Email for Let's Encrypt notifications" ""
done

header "Optional features"

ENABLE_SEARCH=false
if prompt_yn ENABLE_SEARCH "Enable full-text search (Meilisearch)?" "y"; then
  ENABLE_SEARCH=true
fi

ENABLE_VOICE=false
if prompt_yn ENABLE_VOICE "Enable voice & video calls (LiveKit)?" "y"; then
  ENABLE_VOICE=true
fi

ENABLE_EMAIL=false
SMTP_HOST="" SMTP_PORT="587" SMTP_USER="" SMTP_PASS="" SMTP_FROM=""
if prompt_yn ENABLE_EMAIL "Enable email (for registration/password reset)?" "n"; then
  ENABLE_EMAIL=true
  prompt SMTP_HOST "SMTP host"              "smtp.example.com"
  prompt SMTP_PORT "SMTP port"              "587"
  prompt SMTP_USER "SMTP username"          ""
  prompt SMTP_PASS "SMTP password"          ""
  prompt SMTP_FROM "From address"           "noreply@${DOMAIN}"
fi

# ── Generate secrets ──────────────────────────────────────────────────────────
header "Generating secrets…"

SECRET_MEDIA_PROXY=$(gen_secret)
SECRET_ADMIN_KEY=$(gen_secret)
SECRET_ADMIN_OAUTH=$(gen_secret)
SECRET_GATEWAY=$(gen_secret)
SECRET_SUDO=$(gen_secret)
SECRET_CONN=$(gen_secret)

MEILI_KEY=""
if $ENABLE_SEARCH; then
  MEILI_KEY=$(gen_secret)
fi

LIVEKIT_KEY="" LIVEKIT_SECRET=""
if $ENABLE_VOICE; then
  LIVEKIT_KEY=$(openssl rand -hex 8)       # short readable key
  LIVEKIT_SECRET=$(openssl rand -hex 24)   # 48-char secret
fi

VAPID_PUBLIC="" VAPID_PRIVATE=""
info "Generating VAPID keys for web push notifications…"
if VAPID=$(gen_vapid_keys 2>/dev/null); then
  VAPID_PUBLIC="${VAPID%%,*}"
  VAPID_PRIVATE="${VAPID##*,}"
  success "VAPID keys generated."
else
  warn "Node.js not found — VAPID keys skipped. Web push notifications will not work."
  warn "You can add them later: https://docs.fluxer.app/self_hosting/configuration"
  VAPID_PUBLIC="REPLACE_VAPID_PUBLIC_KEY"
  VAPID_PRIVATE="REPLACE_VAPID_PRIVATE_KEY"
fi

success "All secrets generated."

# ── Write .env ────────────────────────────────────────────────────────────────
header "Writing .env…"

cat > .env <<EOF
# Generated by setup.sh — $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Do NOT commit this file to version control.

DOMAIN=${DOMAIN}
LETSENCRYPT_EMAIL=${LE_EMAIL}

FLUXER_IMAGE=ghcr.io/fluxerapp/fluxer-server:stable
FLUXER_PORT=8080

MEILI_MASTER_KEY=${MEILI_KEY}

LIVEKIT_API_KEY=${LIVEKIT_KEY}
LIVEKIT_API_SECRET=${LIVEKIT_SECRET}
EOF

success ".env written."

# ── Write nginx.conf ──────────────────────────────────────────────────────────
header "Writing nginx/nginx.conf…"
sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" nginx/nginx.conf
success "nginx.conf configured for ${DOMAIN}."

# ── Build config.json ─────────────────────────────────────────────────────────
header "Writing config/config.json…"

# Build the email integration block
if $ENABLE_EMAIL; then
  EMAIL_BLOCK=$(cat <<EJSON
    "email": {
      "enabled": true,
      "provider": "smtp",
      "from_email": "${SMTP_FROM}",
      "smtp": {
        "host": "${SMTP_HOST}",
        "port": ${SMTP_PORT},
        "username": "${SMTP_USER}",
        "password": "${SMTP_PASS}",
        "secure": $([ "$SMTP_PORT" = "465" ] && echo true || echo false)
      }
    },
EJSON
)
else
  EMAIL_BLOCK='    "email": { "enabled": false },'
fi

# Build the search integration block
if $ENABLE_SEARCH; then
  SEARCH_BLOCK=$(cat <<SJSON
    "search": {
      "url": "http://meilisearch:7700",
      "api_key": "${MEILI_KEY}"
    }
SJSON
)
else
  SEARCH_BLOCK='    "search": { "enabled": false }'
fi

# Build the voice integration block
if $ENABLE_VOICE; then
  VOICE_BLOCK=$(cat <<VJSON
    "voice": {
      "enabled": true,
      "api_key": "${LIVEKIT_KEY}",
      "api_secret": "${LIVEKIT_SECRET}",
      "url": "wss://${DOMAIN}",
      "webhook_url": "http://fluxer:8080/api/webhooks/livekit",
      "default_region": {
        "id": "default",
        "name": "Default",
        "emoji": "\ud83c\udf10",
        "latitude": 0.0,
        "longitude": 0.0
      }
    }
VJSON
)
else
  VOICE_BLOCK='    "voice": { "enabled": false }'
fi

cat > config/config.json <<EOF
{
  "env": "production",

  "domain": {
    "base_domain": "${DOMAIN}",
    "public_scheme": "https",
    "public_port": 443
  },

  "database": {
    "backend": "sqlite",
    "sqlite_path": "./data/fluxer.db"
  },

  "internal": {
    "kv": "redis://valkey:6379/0"
  },

  "services": {
    "server": {
      "port": 8080,
      "host": "0.0.0.0"
    },
    "media_proxy": {
      "secret_key": "${SECRET_MEDIA_PROXY}"
    },
    "admin": {
      "secret_key_base": "${SECRET_ADMIN_KEY}",
      "oauth_client_secret": "${SECRET_ADMIN_OAUTH}"
    },
    "gateway": {
      "admin_reload_secret": "${SECRET_GATEWAY}",
      "media_proxy_endpoint": "http://127.0.0.1:8080/media"
    }
  },

  "auth": {
    "sudo_mode_secret": "${SECRET_SUDO}",
    "connection_initiation_secret": "${SECRET_CONN}",
    "vapid": {
      "public_key": "${VAPID_PUBLIC}",
      "private_key": "${VAPID_PRIVATE}"
    }
  },

  "integrations": {
${EMAIL_BLOCK}
${SEARCH_BLOCK},
${VOICE_BLOCK}
  }
}
EOF

success "config/config.json written."

# ── Write livekit.yaml ────────────────────────────────────────────────────────
if $ENABLE_VOICE; then
  header "Writing livekit/livekit.yaml…"
  sed \
    -e "s/REPLACE_LIVEKIT_API_KEY/${LIVEKIT_KEY}/g" \
    -e "s/REPLACE_LIVEKIT_API_SECRET/${LIVEKIT_SECRET}/g" \
    livekit/livekit.example.yaml > livekit/livekit.yaml
  success "livekit/livekit.yaml written."
fi

# ── Pull Docker images ────────────────────────────────────────────────────────
header "Pulling Docker images…"
PROFILES=""
$ENABLE_SEARCH && PROFILES="${PROFILES} --profile search"
$ENABLE_VOICE  && PROFILES="${PROFILES} --profile voice"

$COMPOSE $PROFILES pull
success "Images pulled."

# ── Obtain SSL certificate ────────────────────────────────────────────────────
header "Obtaining SSL certificate for ${DOMAIN}…"
info "Starting nginx temporarily for ACME HTTP challenge…"

# Docker prefixes volume names with the compose project name (directory name).
PROJECT_NAME=$(basename "$(pwd)")

# Start nginx in HTTP-only mode for the initial cert request.
# nginx will fail to start with the full config (ssl cert doesn't exist yet),
# so we start with a temporary config that only serves the ACME challenge.
cat > /tmp/nginx-acme-only.conf <<NGINXEOF
events { worker_connections 64; }
http {
  server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ {
      root /var/www/certbot;
    }
    location / { return 200 'waiting for cert'; }
  }
}
NGINXEOF

docker run -d --rm \
  --name fluxer_nginx_acme \
  -p 80:80 \
  -v /tmp/nginx-acme-only.conf:/etc/nginx/nginx.conf:ro \
  -v "${PROJECT_NAME}_certbot_webroot":/var/www/certbot \
  nginx:alpine >/dev/null

info "Running certbot…"
docker run --rm \
  -v "${PROJECT_NAME}_certbot_certs":/etc/letsencrypt \
  -v "${PROJECT_NAME}_certbot_webroot":/var/www/certbot \
  certbot/certbot:latest certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "${LE_EMAIL}" \
    --agree-tos \
    --no-eff-email \
    -d "${DOMAIN}"

docker stop fluxer_nginx_acme >/dev/null 2>&1 || true
success "SSL certificate obtained."

# ── Start the stack ───────────────────────────────────────────────────────────
header "Starting Fluxer…"
$COMPOSE $PROFILES up -d
success "Fluxer is up!"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Fluxer is running at https://${DOMAIN}${RESET}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "  View logs:          ${CYAN}${COMPOSE} logs -f${RESET}"
echo -e "  Stop:               ${CYAN}${COMPOSE} down${RESET}"
echo -e "  Update:             ${CYAN}${COMPOSE} pull && ${COMPOSE} up -d${RESET}"
echo -e "  Check health:       ${CYAN}${COMPOSE} ps${RESET}"
echo ""
if [[ "$VAPID_PUBLIC" == "REPLACE_VAPID_PUBLIC_KEY" ]]; then
  warn "VAPID keys were not generated (Node.js not found)."
  warn "Web push notifications won't work until you add them."
  warn "See README.md → 'Adding VAPID keys later' for instructions."
  echo ""
fi
