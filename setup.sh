#!/bin/bash
set -e

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

# Configuration
ENV_FILE=".env"
UPDATE_SCRIPT="./scripts/update_env_file.sh"
MAX_BACKUPS=3

# --- Logging Functions & Colors ---
# Define colors for log messages
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"

# Function to log messages with a specific color and emoji
log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }
# ------------------------------------

log_info "Starting configuration setup..."

# Self-elevate to root if not already
if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    # shellcheck disable=SC2093
    exec sudo "$0" "$@"
    log_error "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
    exit 1
fi

if [ -x "$UPDATE_SCRIPT" ]; then
    log_info "Running update script: $UPDATE_SCRIPT"
    sudo -u "$REPOSITORY_OWNER" "$UPDATE_SCRIPT"
else
    log_error "Error: $UPDATE_SCRIPT not found or not executable!"
    exit 1
fi

generate_secret() {
    local length="${1:-32}"
    openssl rand -hex "$length"
}

generate_password() {
    openssl rand -base64 24 | tr -d '/+' | cut -c1-24
}

generate_passphrase() {
  local consonants="bcdfghjklmnpqrstvwxyz"
  local vowels="aeiou"
  local word=""
  for i in {1..4}; do
    word+="${consonants:RANDOM%21:1}"
    word+="${vowels:RANDOM%5:1}"
  done
  echo "$word"
}

# Function to check if a variable has the default value from .env.example
is_default_value() {
    local var_name="$1"
    local default_val="$2"
    local current_val
    current_val=$(grep "^${var_name}=" "$ENV_FILE" | cut -d'=' -f2-)

    if [ "$current_val" == "$default_val" ]; then
        return 0 # True, it is default
    else
        return 1 # False, it has been changed
    fi
}

log_info "Checking if secrets need generation..."

# Defaults from .env.example (Hardcoded here for check)
DEFAULT_POSTGRES_PASS="your-super-secret-and-long-postgres-password"
DEFAULT_JWT_SECRET="your-secret-jwt-token-at-least-32-characters-long"
DEFAULT_SECRET_KEY_BASE="your-secret-key-base-at-least-64-characters"
DEFAULT_VAULT_ENC_KEY="your-vault-enc-key-at-least-32-characters"
DEFAULT_DASHBOARD_PASS="this_is_not_a_password"
DEFAULT_DASHBOARD_USER="supabase"
DEFAULT_PG_META_KEY="your-crypto-key-at-least-32-characters"

SECRETS_GENERATED=false


if is_default_value "DASHBOARD_USERNAME" "$DEFAULT_DASHBOARD_USER"; then
    log_info "Generating pronounceable DASHBOARD_USERNAME..."
    NEW_USER=$(generate_passphrase)
    sudo -u "$REPOSITORY_OWNER" sed -i "s|^DASHBOARD_USERNAME=.*|DASHBOARD_USERNAME=${NEW_USER}|" "$ENV_FILE"
    log_success "Generated username: ${NEW_USER}"
fi

if is_default_value "POSTGRES_PASSWORD" "$DEFAULT_POSTGRES_PASS"; then
    log_info "Generating POSTGRES_PASSWORD..."
    PHRASES="$(generate_passphrase)-$(generate_passphrase)-$(generate_passphrase)"
    sudo -u "$REPOSITORY_OWNER" sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PHRASES}|" "$ENV_FILE"
fi

if is_default_value "SECRET_KEY_BASE" "$DEFAULT_SECRET_KEY_BASE"; then
    log_info "Generating SECRET_KEY_BASE..."
    sudo -u "$REPOSITORY_OWNER" sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(generate_secret)|" "$ENV_FILE"
fi

if is_default_value "VAULT_ENC_KEY" "$DEFAULT_VAULT_ENC_KEY"; then
    log_info "Generating VAULT_ENC_KEY..."
    sudo -u "$REPOSITORY_OWNER" sed -i "s|^VAULT_ENC_KEY=.*|VAULT_ENC_KEY=$(generate_secret 16)|" "$ENV_FILE"
fi

if is_default_value "DASHBOARD_PASSWORD" "$DEFAULT_DASHBOARD_PASS"; then
    log_info "Generating DASHBOARD_PASSWORD..."
    PHRASES="$(generate_passphrase)-$(generate_passphrase)-$(generate_passphrase)"
    sudo -u "$REPOSITORY_OWNER" sed -i "s|^DASHBOARD_PASSWORD=.*|DASHBOARD_PASSWORD=${PHRASES}|" "$ENV_FILE"
fi

if is_default_value "PG_META_CRYPTO_KEY" "$DEFAULT_PG_META_KEY"; then
    log_info "Generating PG_META_CRYPTO_KEY..."
    sudo -u "$REPOSITORY_OWNER" sed -i "s|^PG_META_CRYPTO_KEY=.*|PG_META_CRYPTO_KEY=$(generate_secret)|" "$ENV_FILE"
fi

# ------------------------------------------------------------------------------
# Pgsodium Root Key Generation
# ------------------------------------------------------------------------------
PGSODIUM_KEY_DIR="volumes/db/config/custom"
PGSODIUM_KEY_FILE="$PGSODIUM_KEY_DIR/pgsodium_root.key"

if [ ! -f "$PGSODIUM_KEY_FILE" ]; then
    log_info "Generating pgsodium_root.key..."
    mkdir -p "$PGSODIUM_KEY_DIR"
    # Generate 32 randomized bytes and convert to hex (64 chars)
    openssl rand -hex 32 | tr -d '\n' > "$PGSODIUM_KEY_FILE"
    # Ensure it's readable by the container's postgres user
    chmod 644 "$PGSODIUM_KEY_FILE"
    log_success "Created pgsodium_root.key at $PGSODIUM_KEY_FILE"
else
    log_info "pgsodium_root.key already exists. Skipping."
fi


# JWT Logic: If JWT_SECRET is default, generate it AND regenerate Anon/Service keys
if is_default_value "JWT_SECRET" "$DEFAULT_JWT_SECRET"; then
    log_info "Generating JWT_SECRET and keys..."
    NEW_JWT_SECRET=$(generate_secret)
    sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${NEW_JWT_SECRET}|" "$ENV_FILE"

    cat <<EOF > generate_jwt.py
import sys
import time
import hmac
import hashlib
import json
import base64

def base64url_encode(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=')

def create_jwt(secret, role, expiry_seconds=3153600000): # 100 years default
    header = {"typ": "JWT", "alg": "HS256"}
    payload = {
        "role": role,
        "iss": "supabase",
        "iat": int(time.time()),
        "exp": int(time.time()) + expiry_seconds
    }

    encoded_header = base64url_encode(json.dumps(header).encode('utf-8'))
    encoded_payload = base64url_encode(json.dumps(payload).encode('utf-8'))

    signing_input = f"{encoded_header.decode('utf-8')}.{encoded_payload.decode('utf-8')}"
    signature = hmac.new(secret.encode('utf-8'), signing_input.encode('utf-8'), hashlib.sha256).digest()
    encoded_signature = base64url_encode(signature)

    return f"{signing_input}.{encoded_signature.decode('utf-8')}"

secret = sys.argv[1]
print(f"ANON_KEY={create_jwt(secret, 'anon')}")
print(f"SERVICE_ROLE_KEY={create_jwt(secret, 'service_role')}")
EOF

    # Execute the python script and capture output
    if command -v python3 &>/dev/null; then
        JWT_OUTPUT=$(sudo -u "$REPOSITORY_OWNER" python3 generate_jwt.py "$NEW_JWT_SECRET")

        # Parse the output and update .env
        ANON_KEY=$(echo "$JWT_OUTPUT" | grep ANON_KEY | cut -d'=' -f2)
        SERVICE_KEY=$(echo "$JWT_OUTPUT" | grep SERVICE_ROLE_KEY | cut -d'=' -f2)

        sudo -u "$REPOSITORY_OWNER" sed -i "s|^ANON_KEY=.*|ANON_KEY=${ANON_KEY}|" "$ENV_FILE"
        sudo -u "$REPOSITORY_OWNER" sed -i "s|^SERVICE_ROLE_KEY=.*|SERVICE_ROLE_KEY=${SERVICE_KEY}|" "$ENV_FILE"

        log_success "JWTs generated successfully."
    else
        log_warn "Python3 not found. Using random strings for keys."
        ANON_KEY=$(generate_secret)
        SERVICE_KEY=$(generate_secret)
        sudo -u "$REPOSITORY_OWNER" sed -i "s|^ANON_KEY=.*|ANON_KEY=${ANON_KEY}|" "$ENV_FILE"
        sudo -u "$REPOSITORY_OWNER" sed -i "s|^SERVICE_ROLE_KEY=.*|SERVICE_ROLE_KEY=${SERVICE_KEY}|" "$ENV_FILE"
    fi
    sudo -u "$REPOSITORY_OWNER" rm -f generate_jwt.py
else
    log_info "JWT_SECRET is already set (not default). Skipping JWT regeneration."
fi

log_success "Setup complete! Your environment is ready in ${ENV_FILE}"
