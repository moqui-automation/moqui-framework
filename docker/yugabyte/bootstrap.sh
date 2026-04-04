#!/usr/bin/env bash
set -euo pipefail

# Helpers
log() { printf '[yb-start] %s %s\n' "$(date -Is)" "$*"; }
error() { printf '[yb-start] ERROR: %s\n' "$*" >&2; exit 1; }

# Superuser credentials (to create roles/db/extensions)
YSQL_HOST="${YSQL_HOST:-moqui-storage-engine1}"
YSQL_PORT="${YSQL_PORT:-5433}"
YSQL_SUPERUSER="${YSQL_SUPERUSER:-yugabyte}"
YSQL_SUPERDB="${YSQL_SUPERDB:-yugabyte}"
# Moqui credentials
MOQUI_USER="${MOQUI_USER:-moqui}"
MOQUI_PASSWORD="${MOQUI_PASSWORD:-moqui}"
MOQUI_DB="${MOQUI_DB:-moqui}"

YSQLSH="/home/yugabyte/bin/ysqlsh"

pg_ready() {
  for i in $(seq 1 180); do
    if "$YSQLSH" -h "$YSQL_HOST" -p "$YSQL_PORT" -U "$YSQL_SUPERUSER" -d "$YSQL_SUPERDB" -tAc "SELECT 1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  log "Timeout waiting YSQL on $YSQL_HOST:$YSQL_PORT"
  return 1
}

# Setup functions

create_role() {
  local has_role
  has_role="$("$YSQLSH" -h "$YSQL_HOST" -p "$YSQL_PORT" -U "$YSQL_SUPERUSER" -d "$YSQL_SUPERDB" -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='${MOQUI_USER}'" || true)"
  if [[ "$has_role" != "1" ]]; then
    log "Create role ${MOQUI_USER}"
    "$YSQLSH" -h "$YSQL_HOST" -p "$YSQL_PORT" -U "$YSQL_SUPERUSER" -d "$YSQL_SUPERDB" -c \
      "CREATE ROLE ${MOQUI_USER} LOGIN PASSWORD '${MOQUI_PASSWORD}' INHERIT;
       ALTER ROLE ${MOQUI_USER} SET search_path TO public;"
  else
    log "Role ${MOQUI_USER} already defined"
  fi
}

create_database() {
  local has_db
  has_db="$("$YSQLSH" -h "$YSQL_HOST" -p "$YSQL_PORT" -U "$YSQL_SUPERUSER" -d "$YSQL_SUPERDB" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${MOQUI_DB}'" || true)"
  if [[ "$has_db" != "1" ]]; then
    log "Create database ${MOQUI_DB} owner ${MOQUI_USER}"
    "$YSQLSH" -h "$YSQL_HOST" -p "$YSQL_PORT" -U "$YSQL_SUPERUSER" -d "$YSQL_SUPERDB" -c \
      "CREATE DATABASE ${MOQUI_DB} OWNER ${MOQUI_USER} ENCODING 'UTF8';"
  else
    log "Database ${MOQUI_DB} already defined"
  fi
}

install_pgvector() {
  log "Installing pgvector extension on ${MOQUI_DB}..."
  "$YSQLSH" -h "$YSQL_HOST" -p "$YSQL_PORT" -U "$YSQL_SUPERUSER" -d "$MOQUI_DB" -c \
    "CREATE EXTENSION IF NOT EXISTS vector;"
  log "pgvector extension installed."
}

# Smoke Tests

smoke_test() {
  log "Smoke test with user ${MOQUI_USER} on database ${MOQUI_DB}"
  "$YSQLSH" -h "$YSQL_HOST" -p "$YSQL_PORT" -U "$MOQUI_USER" -d "$MOQUI_DB" -tAc \
    "SELECT version(), current_user, current_database();" || {
      log "Smoke test failed"; exit 1; }
  log "OK."
}

smoke_test_pgvector() {
  log "Smoke test: verifying pgvector visibility for ${MOQUI_USER}..."
  local has_vector
  has_vector="$("$YSQLSH" -h "$YSQL_HOST" -p "$YSQL_PORT" -U "$MOQUI_USER" -d "$MOQUI_DB" -tAc \
    "SELECT 1 FROM pg_extension WHERE extname = 'vector'" || true)"

  if [[ "$has_vector" != "1" ]]; then
    log "Smoke test FAILED: User ${MOQUI_USER} cannot see 'vector' extension."
    exit 1
  fi
  log "pgvector check successful."
}

# Main

log "Waiting YSQL on ${YSQL_HOST}:${YSQL_PORT}..."
pg_ready

log "Database setup"
create_role
create_database

log "Extension setup"
install_pgvector

log "Smoke tests"
smoke_test
smoke_test_pgvector

log "Bootstrap complete"
