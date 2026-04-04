#!/bin/bash
set -euo pipefail

# This is a script to do a rotating backup of YugabyteDB (default once per day, retain 30 days)
# It uses native distributed snapshots (yb-admin) for cluster-wide consistency and performance.
# For a complete backup solution these backup files would be copied to a remote site, potentially with a different retention pattern.


# YugabyteDB cluster info
# Comma-separated list of the yugabyte master addresses and their RPC port (7100)
YB_MASTER_ADDRESSES="moqui-database1:7100,moqui-database2:7100,moqui-database3:7100"
DB_NAME="moqui"
# Full path to the yb-admin utility
YB_ADMIN="/home/yugabyte/bin/yb-admin"

# Other options
# a full path from root should be used for backup_path or there will be issues running via crontab
backup_path="/opt/pgbackups"
date=$(date +"%Y%m%d")
# Number of parallel jobs for compression
n=8
KEYSPACE_NAME="ysql.${DB_NAME}"
BACKUP_DIR_NAME="${DB_NAME}-${date}"
BACKUP_DIR_PATH="${backup_path}/${BACKUP_DIR_NAME}"
backup_file="${backup_path}/${BACKUP_DIR_NAME}.tar.gz"

# NOTE: yb-admin authentication is not via .pgpass.
# If your cluster has TLS enabled, add --certs_dir_path ./certs to all yb-admin commands.
# This script assumes a local cluster without TLS.

log() {
  printf '[yb_backup] %s\n' "$*"
}

# Remove file/dir for same day if exists
if [ -e "$backup_file" ]; then
    log "Removing existing backup file: $backup_file"
    rm "$backup_file"
fi
if [ -d "$BACKUP_DIR_PATH" ]; then
    log "Removing existing export directory: $BACKUP_DIR_PATH"
    rm -rf "$BACKUP_DIR_PATH"
fi

# Set default file permissions
umask 177

log "Creating snapshot for keyspace ${KEYSPACE_NAME}..."
SNAPSHOT_ID=$("$YB_ADMIN" -master_addresses "$YB_MASTER_ADDRESSES" create_snapshot "$KEYSPACE_NAME" | grep -oP '(?<=Snapshot ID: ).*')

if [ -z "$SNAPSHOT_ID" ]; then
  log "ERROR: Failed to create snapshot. Exiting."
  exit 1
fi
log "Snapshot created successfully. ID: $SNAPSHOT_ID"

log "Exporting snapshot $SNAPSHOT_ID to ${BACKUP_DIR_PATH}..."
"$YB_ADMIN" -master_addresses "$YB_MASTER_ADDRESSES" export_snapshot "$SNAPSHOT_ID" "file://${BACKUP_DIR_PATH}"
log "Export complete."

log "Deleting snapshot $SNAPSHOT_ID from cluster..."
"$YB_ADMIN" -master_addresses "$YB_MASTER_ADDRESSES" delete_snapshot "$SNAPSHOT_ID"

log "Compressing ${BACKUP_DIR_NAME} to ${backup_file} using $n jobs..."
tar -cf - -C "$backup_path" "$BACKUP_DIR_NAME" | pigz -p "$n" > "$backup_file"
log "Compression complete."

log "Cleaning up temporary export directory ${BACKUP_DIR_PATH}..."
rm -rf "$BACKUP_DIR_PATH"

log "Deleting backups older than 30 days..."
find "$backup_path" -name "*.tar.gz" -mtime +30 -exec rm {} \;

log "YugabyteDB backup complete: $backup_file"

# YugabyteDB restore
# TEST_DB_NAME="moqui-test"
# TEMP_RESTORE_DIR_NAME="${DB_NAME}-${date}"
# TEMP_RESTORE_PATH="/tmp/${TEMP_RESTORE_DIR_NAME}"
#
# log "Restore to ${TEST_DB_NAME}..."
#
# log "Decompressing $backup_file to /tmp..."
# mkdir -p /tmp
# tar -xzf "$backup_file" -C /tmp
#
# log "Create the target test database (if it doesn't exist)..."
# /home/yugabyte/bin/ysqlsh -h moqui-storage-engine1 -U yugabyte -c "CREATE DATABASE ${TEST_DB_NAME};" || true
#
# log "Import the snapshot into the new keyspace..."
# "$YB_ADMIN" -master_addresses "$YB_MASTER_ADDRESSES" \
#   import_snapshot "file://${TEMP_RESTORE_PATH}" "ysql.${DB_NAME}" "ysql.${TEST_DB_NAME}"
#
# log "Clean up temporary restore directory..."
# rm -rf "$TEMP_RESTORE_PATH"
#
# log "Restore complete."

# example for crontab (safe edit using: 'crontab -e'), each day at midnight: 00 00 * * * /opt/moqui/yugabyte_backup.sh
