#!/bin/bash

# This script creates a backup of the Supabase database and storage volumes.

# --- Logging Functions & Colors ---
# Define colors for log messages
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
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

function main() {
  # Resolve script directory and project root
  # Detect Repository Owner to run non-root commands as that user
  CURRENT_DIR=$(dirname "$(readlink -f "$0")")
  CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
  PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
  SERVICE_NAME=$(basename "$PATH_TO_ODOO")
  REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")
  PROJECT_ROOT="$PATH_TO_ODOO"

  echo "-------------------------------------------------------------------------------"
  echo " SUPABASE BACKUP @ $(date +"%A, %d %B %Y %H:%M %Z")"
  echo "-------------------------------------------------------------------------------"

  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
      log_info "Elevating permissions to root..."
      exec sudo "$0" "$@"
      log_error "Failed to elevate to root. Please run with sudo."
      exit 1
  fi

  if ! cd "$PROJECT_ROOT"; then
    log_error "Failed to change directory to $PROJECT_ROOT"
    exit 1
  fi

  # Load .env variables (optional, mostly for checking if needed, but docker compose usually handles it)
  # Docker compose will automatically pick up the .env file in the directory.
  # We do not need to source it here, avoiding potential syntax errors from non-standard .env content.
  if [ ! -f .env ]; then
      log_warn ".env file not found. Docker compose might warn about missing variables."
  fi

  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  BACKUP_DIR="backups/backup_${TIMESTAMP}"

  log_info "Creating backup directory: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"

  # 1. Backup Database
  log_info "Backing up PostgreSQL database..."
  if docker compose exec -T db pg_dumpall -c --if-exists -U postgres > "$BACKUP_DIR/db_dump.sql"; then
      log_success "Database dump created."

      # Compress the dump
      if command -v zstd &> /dev/null; then
           tar -I "zstd -vT0" -cf "$BACKUP_DIR/db_dump.tar.zst" -C "$BACKUP_DIR" db_dump.sql
           rm "$BACKUP_DIR/db_dump.sql"
           log_success "Database backup compressed (zstd)."
      else
           tar -czf "$BACKUP_DIR/db_dump.tar.gz" -C "$BACKUP_DIR" db_dump.sql
           rm "$BACKUP_DIR/db_dump.sql"
           log_warn "zstd not found. Database backup compressed (gzip)."
      fi
  else
      log_error "Database backup failed! Is the 'db' container running?"
      # Clean up if critical failure? keeping incomplete backup might be useful for debugging
  fi

  # 1.5 Backup db-config (pgsodium keys, custom config)
  log_info "Backing up db-config volume (pgsodium keys)..."
  DB_CONTAINER=$(docker compose ps -q db)
  if [ -n "$DB_CONTAINER" ]; then
       # We use volumes-from to access the volume mounted at /etc/postgresql-custom
       # We stream the tar output to stdout to avoid permission issues with mapped volumes
       # Using zstd for compression. Installing zstd and GNU tar (for -I support) in alpine.
       if docker run --rm --volumes-from "$DB_CONTAINER" alpine sh -c "apk add --no-cache zstd tar >/dev/null 2>&1 && tar -I 'zstd -vT0' -cf - -C /etc/postgresql-custom ." > "$BACKUP_DIR/db-config.tar.zst"; then
           log_success "db-config backup successful."
       else
           log_error "db-config backup failed!"
       fi
  else
       log_warn "DB container not found. Cannot determine db-config volume to backup via --volumes-from."
       # Fallback or just warn? If DB is down, ps -q still works if container exists.
       # If container is removed, we might need 'docker volume ls'.
       # But user should have the stack somewhat present.
  fi

  # 2. Backup Storage (volumes/storage)
  # The storage volume is mapped to ./volumes/storage
  if [ -d "volumes/storage" ]; then
      log_info "Backing up Storage volume..."
      # Use tar to archive the directory, preserving permissions
      # We assume we have read permissions or run as sufficient user
      # Using zstd for compression
      if command -v zstd &> /dev/null; then
          tar -I "zstd -vT0" -cf "$BACKUP_DIR/storage.tar.zst" -C volumes storage
          log_success "Storage backup successful."
      else
          log_warn "zstd not found on host. Falling back to gzip."
          tar -czf "$BACKUP_DIR/storage.tar.gz" -C volumes storage
          log_success "Storage backup successful (gzip fallback)."
      fi
  else
      log_warn "volumes/storage directory not found. Skipping storage backup."
  fi

  # 3. Backup .env file
  if [ -f ".env" ]; then
      log_info "Backing up .env file..."
      cp .env "$BACKUP_DIR/.env"
  fi

  # 4. Set permissions
  log_info "Setting permissions for backup files..."
  # Recursively set ownership to REPOSITORY_OWNER for the backup directory
  chown -R "$REPOSITORY_OWNER": "$BACKUP_DIR"

  log_success "Backup process finished. Backup location: $BACKUP_DIR"
}

main
