#!/usr/bin/env bash
# ==============================================================================
# Script: cleanup_expired_vms.sh
# Description: Queries SQLite DB for expired VMs and removes them via Incus.
# Suitable for cron or periodic background execution.
# ==============================================================================

set -euo pipefail

DB_FILE="${1:-data/vms.db}"
DRY_RUN="${DRY_RUN:-0}"

if [[ ! -f "$DB_FILE" ]]; then
    echo "[INFO] SQLite database file not found at $DB_FILE. Nothing to clean up."
    exit 0
fi

echo "[INFO] Checking for expired VMs in database: $DB_FILE (Current UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ'))"

INCUS_BIN="$(command -v incus || true)"

# Query expired VM identifiers where valid_thru <= current timestamp
EXPIRED_VMS=$(sqlite3 "$DB_FILE" "SELECT vm_identifier, valid_thru FROM vms WHERE valid_thru IS NOT NULL AND valid_thru <= datetime('now');" 2>/dev/null || true)

if [[ -z "$EXPIRED_VMS" ]]; then
    echo "[INFO] No expired VMs found."
    exit 0
fi

while IFS='|' read -r vm_id valid_thru; do
    if [[ -z "$vm_id" ]]; then
        continue
    fi

    echo "----------------------------------------------------"
    echo "[EXPIRED] VM Identifier: $vm_id (Expired at: $valid_thru)"

    if [[ -z "$INCUS_BIN" || "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Would execute: incus stop \"$vm_id\" --force"
        echo "  [DRY-RUN] Would execute: incus delete \"$vm_id\" --force"
    else
        echo "  Stopping instance $vm_id..."
        incus stop "$vm_id" --force || true
        echo "  Deleting instance $vm_id..."
        incus delete "$vm_id" --force || true
    fi

    # Delete or mark removed in SQLite
    sqlite3 "$DB_FILE" "DELETE FROM vms WHERE vm_identifier = '$vm_id';"
    echo "  [SUCCESS] Removed $vm_id from database."
done <<< "$EXPIRED_VMS"

echo "[INFO] Cleanup cycle completed."
