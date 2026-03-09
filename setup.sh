#!/usr/bin/env bash
# setup.sh — One-click Conduit Matrix Server deployment
# https://github.com/your-username/matrix-conduit-deploy

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_CMD=""

# ─── Helpers ──────────────────────────────────────────────────────────────────
print_banner() {
  echo -e "${CYAN}${BOLD}"
  cat << 'BANNER'

  ███╗   ███╗ █████╗ ████████╗██████╗ ██╗██╗  ██╗
  ████╗ ████║██╔══██╗╚══██╔══╝██╔══██╗██║╚██╗██╔╝
  ██╔████╔██║███████║   ██║   ██████╔╝██║ ╚███╔╝
  ██║╚██╔╝██║██╔══██║   ██║   ██╔══██╗██║ ██╔██╗
  ██║ ╚═╝ ██║██║  ██║   ██║   ██║  ██║██║██╔╝ ██╗
  ╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝

BANNER
  echo -e "${NC}${BOLD}  Conduit Matrix Server — One-Click Deployment${NC}"
  echo -e "  Matrix homeserver + Voice/Video (LiveKit) + TURN"
  echo
}

step()  { echo -e "\n${BLUE}${BOLD}▶  $1${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC}  $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "  ${RED}✗${NC}  $1"; }
info()  { echo -e "  ${CYAN}ℹ${NC}  $1"; }

ask() {
  local prompt="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    echo -ne "  ${BOLD}${prompt}${NC} [${CYAN}${default}${NC}]: "
  else
    echo -ne "  ${BOLD}${prompt}${NC}: "
  fi
  read -r value
  echo "${value:-$default}"
}

ask_choice() {
  # ask_choice "Question" default opt1_label opt2_label ...
  local prompt="$1" default="$2"
  shift 2
  local opts=("$@")
  local i=1
  for opt in "${opts[@]}"; do
    if [[ "$i" == "$default" ]]; then
      echo -e "    ${CYAN}[${i}]${NC} ${opt} ${YELLOW}(default)${NC}"
    else
      echo -e "    [${i}] ${opt}"
    fi
    ((i++))
  done
  local value
  value=$(ask "Choose" "$default")
  echo "$value"
}

gen_hex()  { openssl rand -hex "$1"; }
gen_b64()  { openssl rand -base64 "$1" | tr -d '=\n/+' | head -c "$1"; }

# ─── 1. Preflight checks ──────────────────────────────────────────────────────
check_prerequisites() {
  step "Checking prerequisites"

  local missing=()

  for cmd in docker openssl curl; do
    if command -v "$cmd" &>/dev/null; then
      ok "$cmd"
    else
      err "$cmd — not found"
      missing+=("$cmd")
    fi
  done

  if docker compose version &>/dev/null 2>&1; then
    ok "docker compose (v2)"
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose &>/dev/null; then
    ok "docker-compose (v1)"
    COMPOSE_CMD="docker-compose"
  else
    err "docker compose — not found"
    missing+=("docker-compose")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo
    err "Missing: ${missing[*]}"
    echo -e "  Install the missing tools and re-run the script."
    echo -e "  Quick install on Ubuntu/Debian:"
    echo -e "    ${CYAN}sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 curl openssl${NC}"
    exit 1
  fi
}

# ─── 2. Gather settings ───────────────────────────────────────────────────────
gather_settings() {
  step "Configuration"
  echo
  info "This script will set up the following subdomains."
  info "Make sure all 4 A records point to this server's IP before starting."
  echo

  DOMAIN=$(ask "Your main domain (e.g. example.com)")
  while [[ -z "$DOMAIN" ]]; do
    warn "Domain cannot be empty."
    DOMAIN=$(ask "Your main domain")
  done
  # strip leading/trailing whitespace and any protocol prefix
  DOMAIN="${DOMAIN#*://}"
  DOMAIN="${DOMAIN%%/*}"

  # Auto-detect public IP
  local auto_ip
  auto_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null \
         || curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
         || echo "")

  SERVER_IP=$(ask "Server public IP" "$auto_ip")
  while [[ -z "$SERVER_IP" ]]; do
    warn "IP address cannot be empty."
    SERVER_IP=$(ask "Server public IP")
  done

  ADMIN_EMAIL=$(ask "Admin email (for Let's Encrypt)" "admin@${DOMAIN}")

  echo
  echo -e "  ${BOLD}Subdomains that will be configured:${NC}"
  printf "    ${CYAN}%-30s${NC} %s\n" "${DOMAIN}"       "Matrix homeserver (Conduit)"
  printf "    ${CYAN}%-30s${NC} %s\n" "call.${DOMAIN}"  "Element Call — voice/video client"
  printf "    ${CYAN}%-30s${NC} %s\n" "sfu.${DOMAIN}"   "LiveKit SFU (WebRTC media server)"
  printf "    ${CYAN}%-30s${NC} %s\n" "turn.${DOMAIN}"  "TURN server (NAT traversal)"
  echo

  TURN_MIN_PORT=$(ask "TURN relay port range — start" "50000")
  TURN_MAX_PORT=$(ask "TURN relay port range — end"   "50100")

  echo
  echo -e "  ${BOLD}Registration mode:${NC}"
  echo -e "    [1] Token-only ${YELLOW}(recommended)${NC} — only invited users can register"
  echo -e "    [2] Open — anyone can create an account"
  local reg_choice
  reg_choice=$(ask "Choose [1/2]" "1")
  REG_MODE="${reg_choice:-1}"
}

# ─── 3. Generate secrets ──────────────────────────────────────────────────────
generate_secrets() {
  step "Generating secrets"

  TURN_SHARED_SECRET=$(gen_hex 32)
  LIVEKIT_API_KEY="lk_$(gen_hex 6)"
  LIVEKIT_API_SECRET=$(gen_hex 32)
  REGISTRATION_TOKEN=$(gen_hex 32)

  ok "TURN shared secret      — generated"
  ok "LiveKit API key/secret  — generated"
  ok "Registration token      — ${BOLD}${REGISTRATION_TOKEN}${NC}"
  echo
  warn "Write down the registration token — users need it to create accounts!"
}

# ─── 4. DNS instructions ──────────────────────────────────────────────────────
print_dns_instructions() {
  step "DNS — Required A Records"
  echo
  echo -e "  Add these A records in your DNS provider (Cloudflare, Namecheap, etc.):"
  echo
  echo -e "  ┌──────────────────────────────────┬──────────────────┐"
  echo -e "  │ ${BOLD}Hostname${NC}                         │ ${BOLD}IP Address${NC}       │"
  echo -e "  ├──────────────────────────────────┼──────────────────┤"
  printf  "  │ ${CYAN}%-32s${NC} │ %-16s │\n" "${DOMAIN}"       "${SERVER_IP}"
  printf  "  │ ${CYAN}%-32s${NC} │ %-16s │\n" "call.${DOMAIN}"  "${SERVER_IP}"
  printf  "  │ ${CYAN}%-32s${NC} │ %-16s │\n" "sfu.${DOMAIN}"   "${SERVER_IP}"
  printf  "  │ ${CYAN}%-32s${NC} │ %-16s │\n" "turn.${DOMAIN}"  "${SERVER_IP}"
  echo -e "  └──────────────────────────────────┴──────────────────┘"
  echo
  warn "DNS propagation may take a few minutes."
  warn "Caddy needs DNS to resolve before it can obtain TLS certificates."
  echo
  echo -ne "  Press ${BOLD}Enter${NC} once the DNS records are saved (Ctrl+C to abort)... "
  read -r
}

# ─── 5. Write all config files ────────────────────────────────────────────────
write_configs() {
  step "Writing configuration files"

  # .env ───────────────────────────────────────────────────────────────────────
  cat > "${SCRIPT_DIR}/.env" << EOF
# Generated by setup.sh — $(date -u '+%Y-%m-%d %H:%M UTC')
# Do NOT commit this file to version control.

# Domain
SERVER_NAME=${DOMAIN}
CONDUIT_PORT=6167

# TURN
TURN_HOST=turn.${DOMAIN}
TURN_REALM=${DOMAIN}
TURN_TTL=3600
TURN_SHARED_SECRET=${TURN_SHARED_SECRET}
TURN_LISTENING_IP=${SERVER_IP}
TURN_RELAY_IP=${SERVER_IP}
TURN_EXTERNAL_IP=${SERVER_IP}
TURN_MIN_PORT=${TURN_MIN_PORT}
TURN_MAX_PORT=${TURN_MAX_PORT}

# LiveKit
LIVEKIT_API_KEY=${LIVEKIT_API_KEY}
LIVEKIT_API_SECRET=${LIVEKIT_API_SECRET}
LIVEKIT_TURN_USER=lkuser
LIVEKIT_TURN_PASS=lkpass
LIVEKIT_URL=wss://sfu.${DOMAIN}
LIVEKIT_JWT_PORT=8080

# Caddy / Let's Encrypt
ADMIN_EMAIL=${ADMIN_EMAIL}
EOF
  ok ".env"

  # conduit/conduit.toml ───────────────────────────────────────────────────────
  mkdir -p "${SCRIPT_DIR}/conduit"
  local allow_reg reg_token_line
  if [[ "$REG_MODE" == "2" ]]; then
    allow_reg="true"
    reg_token_line=""
  else
    allow_reg="false"
    reg_token_line="registration_token = \"${REGISTRATION_TOKEN}\""
  fi

  cat > "${SCRIPT_DIR}/conduit/conduit.toml" << EOF
[global]
server_name = "${DOMAIN}"
address = "0.0.0.0"
port = 6167
max_request_size = 20_000_000

allow_registration = ${allow_reg}
allow_encryption = true
allow_federation = true
${reg_token_line}

database_backend = "rocksdb"
database_path = "/var/lib/matrix-conduit/"

turn_uris = [
  "turn:turn.${DOMAIN}:3478?transport=udp",
  "turn:turn.${DOMAIN}:3478?transport=tcp",
  "turns:turn.${DOMAIN}:5349?transport=tcp"
]
turn_secret = "${TURN_SHARED_SECRET}"
turn_ttl = 3600
EOF
  ok "conduit/conduit.toml"

  # livekit/livekit.yaml ───────────────────────────────────────────────────────
  mkdir -p "${SCRIPT_DIR}/livekit"
  cat > "${SCRIPT_DIR}/livekit/livekit.yaml" << EOF
port: 7880
log_level: info

keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}

rtc:
  port_range_start: 49160
  port_range_end: 49200
  use_external_ip: true
  stun_servers:
    - stun.l.google.com:19302
  turn_servers:
    - host: turn.${DOMAIN}
      port: 3478
      protocol: [udp, tcp]
      username: lkuser
      credential: lkpass
    - host: turn.${DOMAIN}
      port: 5349
      protocol: tls
      username: lkuser
      credential: lkpass
EOF
  ok "livekit/livekit.yaml"

  # coturn/turnserver.conf ─────────────────────────────────────────────────────
  mkdir -p "${SCRIPT_DIR}/coturn"
  cat > "${SCRIPT_DIR}/coturn/turnserver.conf" << EOF
listening-ip=${SERVER_IP}
relay-ip=${SERVER_IP}
external-ip=${SERVER_IP}

listening-port=3478
tls-listening-port=5349

min-port=${TURN_MIN_PORT}
max-port=${TURN_MAX_PORT}

cert=/etc/letsencrypt/live/turn.${DOMAIN}/fullchain.pem
pkey=/etc/letsencrypt/live/turn.${DOMAIN}/privkey.pem

realm=${DOMAIN}
use-auth-secret
static-auth-secret=${TURN_SHARED_SECRET}
fingerprint
no-cli
EOF
  ok "coturn/turnserver.conf"

  # element-call/config.json ───────────────────────────────────────────────────
  mkdir -p "${SCRIPT_DIR}/element-call"
  cat > "${SCRIPT_DIR}/element-call/config.json" << EOF
{
  "base_url": "https://${DOMAIN}",
  "homeserver": "${DOMAIN}",
  "jwt_service_url": "https://sfu.${DOMAIN}/sfu/get",
  "livekit_service_url": "wss://sfu.${DOMAIN}"
}
EOF
  ok "element-call/config.json"

  # well-known ─────────────────────────────────────────────────────────────────
  mkdir -p "${SCRIPT_DIR}/well-known/matrix"
  printf '{"m.server":"%s:443"}' "${DOMAIN}" \
    > "${SCRIPT_DIR}/well-known/matrix/server"
  cat > "${SCRIPT_DIR}/well-known/matrix/client" << EOF
{
  "m.homeserver": { "base_url": "https://${DOMAIN}" },
  "org.matrix.msc4143.rtc_foci": [
    { "type": "livekit", "livekit_service_url": "https://sfu.${DOMAIN}" }
  ]
}
EOF
  ok "well-known/matrix/server + client"

  # caddy/Caddyfile ────────────────────────────────────────────────────────────
  mkdir -p "${SCRIPT_DIR}/caddy"
  cat > "${SCRIPT_DIR}/caddy/Caddyfile" << EOF
{
  email ${ADMIN_EMAIL}
}

${DOMAIN} {
  encode zstd gzip

  # Matrix .well-known discovery
  handle_path /.well-known/matrix/* {
    root * /srv/well-known/matrix
    header Content-Type "application/json"
    header Access-Control-Allow-Origin "*"
    try_files {path} {path}.json
    file_server
  }

  # Matrix API
  handle /_matrix/* {
    reverse_proxy conduit:6167
  }

  respond "Matrix homeserver ${DOMAIN}" 200
}

call.${DOMAIN} {
  encode zstd gzip

  # Dynamic TURN credentials
  handle /config.json {
    reverse_proxy turn-config:3000
  }

  # Element Call SPA
  handle {
    reverse_proxy element-call:8080
  }
}

sfu.${DOMAIN} {
  encode zstd gzip

  handle /sfu/get* {
    reverse_proxy lk-jwt:8080
  }

  handle /healthz {
    reverse_proxy lk-jwt:8080
  }

  reverse_proxy livekit:7880
}
EOF
  ok "caddy/Caddyfile"
}

# ─── 6. Launch ────────────────────────────────────────────────────────────────
start_stack() {
  echo
  echo -ne "  ${BOLD}Start the server now?${NC} [Y/n]: "
  read -r answer

  if [[ "${answer,,}" == "n" ]]; then
    echo
    info "Run manually when ready:"
    echo -e "    ${CYAN}cd ${SCRIPT_DIR} && ${COMPOSE_CMD} up -d${NC}"
    return
  fi

  step "Starting services"
  cd "${SCRIPT_DIR}"
  $COMPOSE_CMD pull --quiet
  $COMPOSE_CMD up -d
  ok "All services started"
}

# ─── 7. Summary ───────────────────────────────────────────────────────────────
print_summary() {
  echo
  echo -e "  ╔══════════════════════════════════════════════════════════╗"
  echo -e "  ║  ${GREEN}${BOLD}Setup complete!${NC}                                         ║"
  echo -e "  ╚══════════════════════════════════════════════════════════╝"
  echo
  echo -e "  ${BOLD}Your Matrix server:${NC}"
  echo -e "    Homeserver   : ${CYAN}https://${DOMAIN}${NC}"
  echo -e "    Element Call : ${CYAN}https://call.${DOMAIN}${NC}"
  echo -e "    SFU          : ${CYAN}https://sfu.${DOMAIN}${NC}"
  echo
  if [[ "$REG_MODE" != "2" ]]; then
    echo -e "  ${BOLD}Registration token:${NC}"
    echo -e "    ${CYAN}${REGISTRATION_TOKEN}${NC}"
    echo -e "    ${YELLOW}Share this only with people you want to allow to register.${NC}"
    echo
  fi
  echo -e "  ${BOLD}Matrix ID format:${NC} @username:${DOMAIN}"
  echo
  echo -e "  ${BOLD}Useful commands:${NC}"
  echo -e "    View logs    : ${CYAN}${COMPOSE_CMD} logs -f${NC}"
  echo -e "    Stop server  : ${CYAN}${COMPOSE_CMD} down${NC}"
  echo -e "    Restart      : ${CYAN}${COMPOSE_CMD} restart${NC}"
  echo -e "    Update       : ${CYAN}${COMPOSE_CMD} pull && ${COMPOSE_CMD} up -d${NC}"
  echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  print_banner
  check_prerequisites
  gather_settings
  generate_secrets
  print_dns_instructions
  write_configs
  start_stack
  print_summary
}

main "$@"
