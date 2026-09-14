#!/usr/bin/env sh

source "$HOME/.config/sketchybar/colorpresets/custom-theme.sh"

TAILSCALE_CMD="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

# Colors for each state
COLOR_ON="0xff08F7FE"   # Cyan when connected
COLOR_OFF="0xffA4B3B6"  # Grey when off

# Icon
ICON="󰸳"

# Theme colors for popup
THEME_SAGE="0xffA4B3B6"
THEME_LAVENDER="0xffE98074"

# Handle mouse events for hover popup
if [ "$SENDER" = "mouse.entered" ]; then
  sketchybar --set "$NAME" popup.drawing=on
  exit 0
fi

if [ "$SENDER" = "mouse.exited" ]; then
  sketchybar --set "$NAME" popup.drawing=off
  exit 0
fi

# Get current Tailscale backend state ("Running" when connected, else "off")
get_backend_state() {
  if [ -x "$TAILSCALE_CMD" ]; then
    STATE=$("$TAILSCALE_CMD" status --json 2>/dev/null | jq -r '.BackendState // "off"')
    [ "$STATE" = "Running" ] && echo "Running" || echo "off"
  else
    echo "off"
  fi
}

# Update the bar icon color based on state
update_display() {
  if [ "$1" = "Running" ]; then
    sketchybar --set "$NAME" icon="$ICON" icon.color="$COLOR_ON"
  else
    sketchybar --set "$NAME" icon="$ICON" icon.color="$COLOR_OFF"
  fi
}

# Create or update a popup line: $1 = suffix, $2 = label, $3 = color
set_popup_line() {
  sketchybar --set "$NAME.$1" label="$2" drawing=on 2>/dev/null || \
    sketchybar --add item "$NAME.$1" popup."$NAME" \
      --set "$NAME.$1" label="$2" \
        label.font="Iosevka Nerd Font:Regular:13.0" label.color="$3"
}

# Update popup contents for the given state
update_popup() {
  sketchybar --set "$NAME" popup.align=center

  if [ "$1" = "Running" ]; then
    TAILNET=$("$TAILSCALE_CMD" status --json 2>/dev/null | jq -r '.CurrentTailnet.Name // empty')
    TS_IP=$("$TAILSCALE_CMD" ip -4 2>/dev/null | head -n1)

    set_popup_line status "Status: Connected" "$THEME_SAGE"

    if [ -n "$TAILNET" ]; then
      set_popup_line tailnet "Tailnet: $TAILNET" "$THEME_SAGE"
    else
      sketchybar --set "$NAME.tailnet" drawing=off 2>/dev/null
    fi

    if [ -n "$TS_IP" ]; then
      set_popup_line ip "IP: $TS_IP" "$THEME_LAVENDER"
    else
      sketchybar --set "$NAME.ip" drawing=off 2>/dev/null
    fi
  else
    set_popup_line status "Status: Off" "$THEME_SAGE"
    sketchybar --set "$NAME.tailnet" drawing=off 2>/dev/null
    sketchybar --set "$NAME.ip" drawing=off 2>/dev/null
  fi
}

# Handle clicks - any button toggles Tailscale on/off
if [ "$SENDER" = "mouse.clicked" ]; then
  CURRENT=$(get_backend_state)

  if [ "$CURRENT" = "Running" ]; then
    NEXT="off"
  else
    NEXT="Running"
  fi

  # Update display and popup IMMEDIATELY (before the actual toggle)
  update_display "$NEXT"
  sketchybar --set "$NAME" popup.align=center
  if [ "$NEXT" = "off" ]; then
    set_popup_line status "Status: Disconnecting..." "$THEME_SAGE"
    sketchybar --set "$NAME.tailnet" drawing=off 2>/dev/null
    sketchybar --set "$NAME.ip" drawing=off 2>/dev/null
  else
    set_popup_line status "Status: Connecting..." "$THEME_SAGE"
  fi

  # Run the actual toggle in background, then reconcile with real state
  (
    if [ "$NEXT" = "off" ]; then
      "$TAILSCALE_CMD" down 2>/dev/null
      sleep 1
    else
      "$TAILSCALE_CMD" up 2>/dev/null
      # Poll until BackendState is Running (max 10 seconds)
      for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        [ "$(get_backend_state)" = "Running" ] && break
      done
    fi

    FINAL=$(get_backend_state)
    update_display "$FINAL"
    update_popup "$FINAL"
  ) &

  exit 0
fi

# Normal update - reflect actual current state
CURRENT=$(get_backend_state)
update_display "$CURRENT"
update_popup "$CURRENT"
