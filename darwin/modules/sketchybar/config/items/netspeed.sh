#!/bin/bash

source "$HOME/.config/sketchybar/colorpresets/custom-theme.sh"

# Icon and colors
ICON="󰓅"  # Speedometer icon
ICON_COLOR="0xffFFB86C"      # Warm amber/orange for the icon
COLOR_GOOD="0xffA4B3B6"      # Sage - normal speed
COLOR_POOR="0xffFF6B6B"      # Bright red - poor speed (<10 Mbps)
SPEED_THRESHOLD=10           # Mbps threshold for "poor" speed

# Helper: Get label color based on speed
get_speed_color() {
  local SPEED=$1
  if [ -z "$SPEED" ] || [ "$SPEED" = "--" ] || [ "$SPEED" = "—" ]; then
    echo "$COLOR_GOOD"
  elif [ "$SPEED" -lt "$SPEED_THRESHOLD" ] 2>/dev/null; then
    echo "$COLOR_POOR"
  else
    echo "$COLOR_GOOD"
  fi
}

# Handle mouse events for hover popup
if [ "$SENDER" = "mouse.entered" ]; then
  sketchybar --set $NAME popup.drawing=on
  exit 0
fi

if [ "$SENDER" = "mouse.exited" ]; then
  sketchybar --set $NAME popup.drawing=off
  exit 0
fi

# --- Configuration ---
STATE_DIR="/tmp/sketchybar_netspeed"
LOCK_FILE="/tmp/sketchybar_netspeed.lock"
TEST_CMD="networkQuality"
mkdir -p "$STATE_DIR"  # Ensure state directory exists

# --- Acquire Lock (prevent concurrent runs) ---
# Use mkdir for atomic lock (works on macOS)
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
  # Check if lock is stale (older than 2 minutes)
  if [ -d "$LOCK_FILE" ]; then
    # Support both GNU stat (-c) and BSD stat (-f)
    LOCK_MTIME=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null)
    LOCK_AGE=$(( $(date +%s) - ${LOCK_MTIME:-0} ))
    if [ "$LOCK_AGE" -gt 120 ]; then
      echo "Removing stale lock."
      rmdir "$LOCK_FILE" 2>/dev/null
      mkdir "$LOCK_FILE" 2>/dev/null || { echo "Lock contention. Exiting."; exit 0; }
    else
      echo "Another instance is running. Exiting."
      exit 0
    fi
  fi
fi
trap 'rmdir "$LOCK_FILE" 2>/dev/null' EXIT

# --- Helper: Clear error state ---
clear_error() {
  rm -f "$ERROR_FILE"
}

# --- Helper: Set error state with message ---
set_error() {
  local ERROR_MSG=$1
  local RETRY_COUNT=${2:-0}
  echo "${ERROR_MSG}|${RETRY_COUNT}|$(date +%s)" >"$ERROR_FILE"
}

# --- Helper: Update popup with current status ---
update_popup() {
  local STATUS=$1
  local SSID=$2
  local DL_SPEED=$3
  local UL_SPEED=$4
  local RSSI=$5
  local LAST_TEST_TIME=$6

  # Format the last test time
  if [ -n "$LAST_TEST_TIME" ] && [ "$LAST_TEST_TIME" != "0" ]; then
    FORMATTED_TIME=$(date -r "$LAST_TEST_TIME" "+%H:%M:%S" 2>/dev/null || echo "Unknown")
  else
    FORMATTED_TIME="Never"
  fi

  # Theme colors (matching custom-theme.sh)
  THEME_SAGE="0xffA4B3B6"
  THEME_LAVENDER="0xffE98074"
  THEME_PINK="0xffD83F87"

  # Create or update popup items
  sketchybar --set "$NAME" popup.align=center

  # Line 1: Network
  sketchybar --set "$NAME".network label="Network: $SSID" 2>/dev/null || \
    sketchybar --add item "$NAME".network popup."$NAME" \
      --set "$NAME".network label="Network: $SSID" \
        label.font="Iosevka Nerd Font:Regular:13.0" label.color="$THEME_SAGE"

  # Line 2: Download Speed
  sketchybar --set "$NAME".download label="Download: ${DL_SPEED} Mbps" 2>/dev/null || \
    sketchybar --add item "$NAME".download popup."$NAME" \
      --set "$NAME".download label="Download: ${DL_SPEED} Mbps" \
        label.font="Iosevka Nerd Font:Regular:13.0" label.color="$THEME_SAGE"

  # Line 3: Upload Speed
  sketchybar --set "$NAME".upload label="Upload: ${UL_SPEED} Mbps" 2>/dev/null || \
    sketchybar --add item "$NAME".upload popup."$NAME" \
      --set "$NAME".upload label="Upload: ${UL_SPEED} Mbps" \
        label.font="Iosevka Nerd Font:Regular:13.0" label.color="$THEME_SAGE"

  # Line 4: Signal (only for WiFi)
  if [ "$SSID" != "Wired" ] && [ -n "$RSSI" ] && [ "$RSSI" != "0" ]; then
    sketchybar --set "$NAME".signal label="Signal: ${RSSI} dBm" 2>/dev/null || \
      sketchybar --add item "$NAME".signal popup."$NAME" \
        --set "$NAME".signal label="Signal: ${RSSI} dBm" \
          label.font="Iosevka Nerd Font:Regular:13.0" label.color="$THEME_SAGE"
  fi

  # Line 5: Last tested
  sketchybar --set "$NAME".time label="Tested: $FORMATTED_TIME" 2>/dev/null || \
    sketchybar --add item "$NAME".time popup."$NAME" \
      --set "$NAME".time label="Tested: $FORMATTED_TIME" \
        label.font="Iosevka Nerd Font:Regular:13.0" label.color="$THEME_LAVENDER"
}

# --- Helper: Check if in error state and should retry ---
should_retry_error() {
  if [ ! -f "$ERROR_FILE" ]; then
    return 1
  fi

  IFS='|' read -r ERR_MSG ERR_RETRIES ERR_TIME <"$ERROR_FILE"
  NOW=$(date +%s)
  ELAPSED=$((NOW - ERR_TIME))

  # Check if enough time has passed and we haven't exceeded max retries
  if [ "$ELAPSED" -ge "$ERROR_RETRY_INTERVAL" ] && [ "$ERR_RETRIES" -lt "$MAX_RETRIES" ]; then
    return 0
  fi
  return 1
}

# --- Helper: Get current retry count ---
get_retry_count() {
  if [ ! -f "$ERROR_FILE" ]; then
    echo "0"
    return
  fi
  IFS='|' read -r _ ERR_RETRIES _ <"$ERROR_FILE"
  echo "${ERR_RETRIES:-0}"
}

# --- Helper: Run Speed Test ---
run_speed_test() {
  REASON=$1
  RETRY_COUNT=$(get_retry_count)
  echo "--- STARTING SPEED TEST (Reason: $REASON, Retry: $RETRY_COUNT) ---"

  sketchybar --set "$NAME" icon="$ICON" label="..." icon.color=0xffE98074 label.color="$COLOR_GOOD"

  echo "Executing: $TEST_CMD"
  RESULT=$($TEST_CMD 2>&1)
  EXIT_CODE=$?
  echo "Raw Result: $RESULT"
  echo "Exit Code: $EXIT_CODE"

  # Check for command failure
  if [ "$EXIT_CODE" -ne 0 ]; then
    echo "Error: networkQuality command failed with exit code $EXIT_CODE"
    NEW_RETRY=$((RETRY_COUNT + 1))
    set_error "networkQuality failed (exit $EXIT_CODE)" "$NEW_RETRY"
    sketchybar --set "$NAME" icon="$ICON" label="Err" icon.color=0xffE98074 label.color="$COLOR_POOR"
    LAST_TEST=$(cat "$LAST_TEST_FILE" 2>/dev/null || echo "0")
    update_popup "error" "$CURRENT_SSID" "—" "$CURRENT_RSSI" "$LAST_TEST"
    echo "--- TEST FAILED (will retry $NEW_RETRY/$MAX_RETRIES) ---"
    return 1
  fi

  DL_SPEED=$(echo "$RESULT" | grep "Downlink capacity" | awk '{printf "%.0f", $3}')
  UL_SPEED=$(echo "$RESULT" | grep "Uplink capacity" | awk '{printf "%.0f", $3}')

  if [ -z "$DL_SPEED" ] || [ -z "$UL_SPEED" ]; then
    echo "Error: Could not parse speeds (DL: $DL_SPEED, UL: $UL_SPEED)."
    NEW_RETRY=$((RETRY_COUNT + 1))
    set_error "Failed to parse speed result" "$NEW_RETRY"
    sketchybar --set "$NAME" icon="$ICON" label="Err" icon.color=0xffE98074 label.color="$COLOR_POOR"
    LAST_TEST=$(cat "$LAST_TEST_FILE" 2>/dev/null || echo "0")
    update_popup "error" "$CURRENT_SSID" "—" "—" "$CURRENT_RSSI" "$LAST_TEST"
    echo "--- TEST FAILED (will retry $NEW_RETRY/$MAX_RETRIES) ---"
    return 1
  fi

  echo "Parsed Download Speed: $DL_SPEED Mbps, Upload Speed: $UL_SPEED Mbps"

  # Success - clear any error state
  clear_error

  echo "${CURRENT_SSID}|${DL_SPEED}|${UL_SPEED}|${CURRENT_RSSI}" >"$STATE_FILE"
  date +%s >"$LAST_TEST_FILE"
  SPEED_COLOR=$(get_speed_color "$DL_SPEED")
  sketchybar --set "$NAME" icon="$ICON" label="↓${DL_SPEED} ↑${UL_SPEED}" icon.color="$ICON_COLOR" label.color="$SPEED_COLOR"
  update_popup "ok" "$CURRENT_SSID" "$DL_SPEED" "$UL_SPEED" "$CURRENT_RSSI" "$(date +%s)"
  echo "--- TEST COMPLETE ---"
  return 0
}

# --- Main Logic ---

echo "Script triggered."

# 1. Get Current Network Info (using system_profiler for modern macOS compatibility)
WIFI_INFO=$(system_profiler SPAirPortDataType 2>/dev/null)

# Extract SSID from "Current Network Information:" section - the SSID is the line after it ending with ":"
CURRENT_SSID=$(echo "$WIFI_INFO" | awk '/Current Network Information:/{getline; gsub(/^[[:space:]]+|:[[:space:]]*$/, ""); print; exit}')

# Get BSSID (MAC address of access point) for unique network identification
CURRENT_BSSID=$(echo "$WIFI_INFO" | awk '/BSSID:/ {print $2; exit}')

# Get signal strength from system_profiler (no sudo required)
CURRENT_RSSI=$(echo "$WIFI_INFO" | awk -F'[/ ]' '/Signal \/ Noise/ {for(i=1;i<=NF;i++) if($i ~ /^-[0-9]+$/) {print $i; exit}}')
[ -z "$CURRENT_RSSI" ] && CURRENT_RSSI=0

# Check if we successfully got an SSID (WiFi connected) or if it's empty (wired/disconnected)
if [ -z "$CURRENT_SSID" ] || [ "$CURRENT_SSID" = "" ]; then
  echo "No WiFi SSID found. Assuming Wired connection."
  CURRENT_SSID="Wired"
  CURRENT_BSSID="wired"
  CURRENT_RSSI=0
else
  echo "Current Network: $CURRENT_SSID (BSSID: $CURRENT_BSSID, RSSI: $CURRENT_RSSI)"
fi

# Generate network-specific file paths using BSSID
NETWORK_ID=$(echo "$CURRENT_BSSID" | tr ':' '_')  # Replace colons with underscores for filename
STATE_FILE="$STATE_DIR/${NETWORK_ID}_state"
LAST_TEST_FILE="$STATE_DIR/${NETWORK_ID}_last_test"
ERROR_FILE="$STATE_DIR/${NETWORK_ID}_error"

# 2. Click Handler - Manual trigger
if [ "$SENDER" = "mouse.clicked" ]; then
  echo "Manual click detected - running speed test"
  rm -f "$ERROR_FILE"  # Reset retry count on manual click
  run_speed_test "User Clicked"
  exit 0
fi

# 3. Error Retry Check
if should_retry_error; then
  echo "In error state, attempting retry..."
  run_speed_test "Error Retry"
  exit 0
fi

# 4. State Reconciliation - check if we have cached data for this network
if [ ! -f "$STATE_FILE" ]; then
  echo "No cached data for this network - running speed test"
  run_speed_test "First Run / No State File for Network"
  exit 0
fi

# Parse state file (use | as delimiter to handle SSIDs with spaces)
IFS='|' read -r LAST_SSID LAST_DL_SPEED LAST_UL_SPEED LAST_RSSI <"$STATE_FILE"
echo "Previous State: SSID=$LAST_SSID, DL=$LAST_DL_SPEED, UL=$LAST_UL_SPEED, RSSI=$LAST_RSSI"

# 5. Display cached data
echo "Displaying cached data for current network."
SPEED_COLOR=$(get_speed_color "$LAST_DL_SPEED")
sketchybar --set "$NAME" icon="$ICON" label="↓${LAST_DL_SPEED} ↑${LAST_UL_SPEED}" icon.color="$ICON_COLOR" label.color="$SPEED_COLOR"

# Update popup with current state
LAST_TEST=$(cat "$LAST_TEST_FILE" 2>/dev/null || echo "0")
if [ -f "$ERROR_FILE" ]; then
  update_popup "error" "$CURRENT_SSID" "$LAST_DL_SPEED" "$LAST_UL_SPEED" "$CURRENT_RSSI" "$LAST_TEST"
else
  update_popup "ok" "$CURRENT_SSID" "$LAST_DL_SPEED" "$LAST_UL_SPEED" "$CURRENT_RSSI" "$LAST_TEST"
fi
