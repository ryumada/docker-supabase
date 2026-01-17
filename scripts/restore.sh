#!/bin/bash

# This script restores a backup of the Supabase database and storage volumes.
# Usage: ./scripts/restore.sh backups/backup_YYYYMMDD_HHMMSS

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
readonly COLOR_ERROR="\033[0;31m"

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
  BACKUP_PATH="$1"

  # Validate input
  if [ -z "$BACKUP_PATH" ]; then
    log_error "Usage: $0 <path_to_backup_directory>"
    exit 1
  fi

  if [ ! -d "$BACKUP_PATH" ]; then
    log_error "Backup directory not found: $BACKUP_PATH"
    exit 1
  fi

  # Confirm action
  echo "WARNING: This will overwrite the current database and storage volumes."
  read -p "Are you sure you want to proceed? (y/N) " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_info "Restore cancelled."
    exit 0
  fi

  # Detect Repository Owner to run non-root commands as that user
  CURRENT_DIR=$(dirname "$(readlink -f "$0")")
  CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
  PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
  SERVICE_NAME=$(basename "$PATH_TO_ODOO")
  REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")
  PROJECT_ROOT="$PATH_TO_ODOO"

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

  log_info "Starting restore process from: $BACKUP_PATH"

  # 1. Restore Database
  # 1. Restore Database
  DB_DUMP_ZST="$BACKUP_PATH/db_dump.tar.zst"
  DB_DUMP_GZ="$BACKUP_PATH/db_dump.tar.gz"
  DB_DUMP_SQL="$BACKUP_PATH/db_dump.sql"

  # Determine which file to use
  if [ -f "$DB_DUMP_ZST" ]; then
      RESTORE_FILE="$DB_DUMP_ZST"
      METHOD="zstd"
  elif [ -f "$DB_DUMP_GZ" ]; then
      RESTORE_FILE="$DB_DUMP_GZ"
      METHOD="gzip"
  elif [ -f "$DB_DUMP_SQL" ]; then
      RESTORE_FILE="$DB_DUMP_SQL"
      METHOD="sql"
  else
      RESTORE_FILE=""
  fi

  if [ -n "$RESTORE_FILE" ]; then
      log_info "Restoring PostgreSQL database from $RESTORE_FILE..."
      # Check if db container is running
      if ! docker compose ps db | grep -q "Up"; then
          log_warn "DB container is not running. Attempting to start it..."
          docker compose up -d db
          sleep 5 # Wait for it to be ready
      fi

      # Restore based on method
      if [ "$METHOD" == "zstd" ]; then
           # Extract db_dump.sql to stdout and pipe to psql
           tar -I zstd -xOf "$RESTORE_FILE" db_dump.sql | docker compose exec -T db psql -U postgres
      elif [ "$METHOD" == "gzip" ]; then
           tar -xzOf "$RESTORE_FILE" db_dump.sql | docker compose exec -T db psql -U postgres
      else
           # Raw SQL
           cat "$RESTORE_FILE" | docker compose exec -T db psql -U postgres
      fi

      if [ $? -eq 0 ]; then
          log_success "Database restored successfully."
      else
          log_error "Database restore failed."
          exit 1
      fi
  else
      log_warn "No database dump found (checked .tar.zst, .tar.gz, .sql). Skipping DB restore."
  fi

  # 1.5 Restore db-config
  DBCONFIG_ARCHIVE="$BACKUP_PATH/db-config.tar.zst"
  # Check for gzip fallback if zst doesn't exist
  if [ ! -f "$DBCONFIG_ARCHIVE" ] && [ -f "$BACKUP_PATH/db-config.tar.gz" ]; then
      DBCONFIG_ARCHIVE="$BACKUP_PATH/db-config.tar.gz"
  fi

  if [ -f "$DBCONFIG_ARCHIVE" ]; then
      log_info "Restoring db-config volume from $DBCONFIG_ARCHIVE..."
      DB_CONTAINER=$(docker compose ps -q db)

      # Ensure DB container exists (even if stopped) so we can mount its volume
      if [ -z "$DB_CONTAINER" ]; then
           log_info "DB container not found. Creating it..."
           docker compose up --no-start db
           DB_CONTAINER=$(docker compose ps -q db)
      fi

      if [ -n "$DB_CONTAINER" ]; then
          # Determine compression type
          if [[ "$DBCONFIG_ARCHIVE" == *.tar.zst ]]; then
              # Install zstd/tar and extract using -I
              docker run --rm --volumes-from "$DB_CONTAINER" -v "$(pwd)/$BACKUP_PATH":/backup alpine sh -c "apk add --no-cache zstd tar >/dev/null 2>&1 && cd /etc/postgresql-custom && tar -I zstd -xf \"/backup/$(basename "$DBCONFIG_ARCHIVE")\""
          else
              # Gzip fallback
              docker run --rm --volumes-from "$DB_CONTAINER" -v "$(pwd)/$BACKUP_PATH":/backup alpine sh -c "cd /etc/postgresql-custom && tar xzf \"/backup/$(basename "$DBCONFIG_ARCHIVE")\""
          fi

          if [ $? -eq 0 ]; then
              log_success "db-config restored successfully."
          else
              log_error "db-config restore failed."
          fi
      else
           log_error "Could not find or create DB container to restore volume."
      fi
  else
      log_warn "No db-config archive found. Skipping."
  fi

  # 2. Restore Storage
  STORAGE_ARCHIVE="$BACKUP_PATH/storage.tar.zst"
  # Check for gzip fallback
  if [ ! -f "$STORAGE_ARCHIVE" ] && [ -f "$BACKUP_PATH/storage.tar.gz" ]; then
      STORAGE_ARCHIVE="$BACKUP_PATH/storage.tar.gz"
  fi

  if [ -f "$STORAGE_ARCHIVE" ]; then
      log_info "Restoring Storage volume from $STORAGE_ARCHIVE..."
      # Warning: this overwrites files in volumes/storage
      # We extract directly into relevant directory.

      if [[ "$STORAGE_ARCHIVE" == *.tar.zst ]]; then
          if command -v zstd &> /dev/null; then
              tar -I zstd -xf "$STORAGE_ARCHIVE" -C volumes
              log_success "Storage restored successfully."
          else
              log_error "zstd not found on host. Cannot restore .tar.zst archive."
          fi
      else
          tar -xzf "$STORAGE_ARCHIVE" -C volumes
          log_success "Storage restored successfully (gzip)."
      fi
  else
      log_warn "No storage archive found at $STORAGE_ARCHIVE. Skipping storage restore."
  fi

  # 3. Restore .env (Optional/Prompt)
  ENV_BACKUP="$BACKUP_PATH/.env"
  if [ -f "$ENV_BACKUP" ]; then
      read -p "Do you want to restore the .env file? (y/N) " restore_env
      if [[ "$restore_env" == "y" || "$restore_env" == "Y" ]]; then
          cp "$ENV_BACKUP" .env
          log_success ".env file restored."
      else
          log_info "Skipping .env restore."
      fi
  fi

  log_success "Restore process finished."
}

main "$@"
