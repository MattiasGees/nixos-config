#!/usr/bin/env bash

# Archive Downloads Script
# Moves all items in ~/Downloads (except archive-* folders and hidden files)
# into a new archive folder with the current date

set -euo pipefail

DOWNLOADS_DIR="$HOME/Downloads"
DATE=$(date +%Y-%m-%d)
ARCHIVE_DIR="$DOWNLOADS_DIR/archive-$DATE"

# Log file for debugging
if [ "$(uname)" = "Darwin" ]; then
    LOG_DIR="$HOME/Library/Logs"
else
    LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/archive-downloads.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "Starting Downloads archive process"

# Check if Downloads directory exists
if [ ! -d "$DOWNLOADS_DIR" ]; then
    log "ERROR: Downloads directory does not exist"
    exit 1
fi

# Change to Downloads directory
cd "$DOWNLOADS_DIR"

# Count items to archive (excluding hidden files and archive-* folders)
ITEMS_TO_ARCHIVE=()
for item in *; do
    # Skip if glob didn't match anything
    [ -e "$item" ] || continue

    # Skip archive-* folders
    if [[ "$item" == archive-* ]]; then
        log "Skipping existing archive folder: $item"
        continue
    fi

    ITEMS_TO_ARCHIVE+=("$item")
done

# Check if there's anything to archive
if [ ${#ITEMS_TO_ARCHIVE[@]} -eq 0 ]; then
    log "No items to archive in Downloads"
    exit 0
fi

log "Found ${#ITEMS_TO_ARCHIVE[@]} item(s) to archive"

# Create archive directory
mkdir -p "$ARCHIVE_DIR"
log "Created archive directory: $ARCHIVE_DIR"

# Move items to archive
MOVED_COUNT=0
FAILED_COUNT=0

for item in "${ITEMS_TO_ARCHIVE[@]}"; do
    if mv "$item" "$ARCHIVE_DIR/"; then
        log "Moved: $item"
        ((MOVED_COUNT++)) || true
    else
        log "ERROR: Failed to move: $item"
        ((FAILED_COUNT++)) || true
    fi
done

log "Archive complete: $MOVED_COUNT moved, $FAILED_COUNT failed"
log "Archive location: $ARCHIVE_DIR"
