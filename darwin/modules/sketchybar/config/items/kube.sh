#!/usr/bin/env sh

# Explicitly set KUBECONFIG and PATH for brew services compatibility
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="/etc/profiles/per-user/mattias/bin:/opt/homebrew/bin:${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

source "$HOME/.config/sketchybar/colorpresets/custom-theme.sh"

# Icon and colors
ICON="󱃾"
COLOR_CONNECTED="0xff50FA7B"    # Green - connected
COLOR_DISCONNECTED="0xffFF6B6B" # Red - disconnected
COLOR_NO_CONTEXT="0xffA4B3B6"   # Grey - no context

# Max chars to display for context name
MAX_CHARS=12

# Theme colors for popup
THEME_SAGE="0xffA4B3B6"
THEME_LAVENDER="0xffE98074"

# Handle mouse events for hover popup
if [ "$SENDER" = "mouse.entered" ]; then
  sketchybar --set $NAME popup.drawing=on
  exit 0
fi

if [ "$SENDER" = "mouse.exited" ]; then
  sketchybar --set $NAME popup.drawing=off
  exit 0
fi

# Get current context
CONTEXT=$(kubectl config current-context 2>/dev/null)

if [ -z "$CONTEXT" ]; then
  # No context set
  sketchybar --set $NAME icon="$ICON" label="none" icon.color="$COLOR_NO_CONTEXT" label.color="$COLOR_NO_CONTEXT"
  sketchybar --set "$NAME".context label="Context: None" 2>/dev/null || \
    sketchybar --add item "$NAME".context popup."$NAME" \
      --set "$NAME".context label="Context: None" \
        label.font="Iosevka Nerd Font:Regular:13.0" label.color="$THEME_SAGE"
  sketchybar --set "$NAME".status label="Status: No context" drawing=on 2>/dev/null || \
    sketchybar --add item "$NAME".status popup."$NAME" \
      --set "$NAME".status label="Status: No context" \
        label.font="Iosevka Nerd Font:Regular:13.0" label.color="$THEME_SAGE"
  sketchybar --set "$NAME".server drawing=off 2>/dev/null
  exit 0
fi

# Truncate context name for display
CONTEXT_SHORT=$(echo "$CONTEXT" | cut -c1-${MAX_CHARS})
if [ ${#CONTEXT} -gt $MAX_CHARS ]; then
  CONTEXT_SHORT="${CONTEXT_SHORT}…"
fi

# Get API server URL
API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)

# Check connectivity with a quick healthz request (2 second timeout)
HEALTH_CHECK=$(kubectl get --raw /healthz --request-timeout=2s 2>/dev/null)

if [ "$HEALTH_CHECK" = "ok" ]; then
  CONNECTED=true
  ICON_COLOR="$COLOR_CONNECTED"
  STATUS_TEXT="Status: Connected"
else
  CONNECTED=false
  ICON_COLOR="$COLOR_DISCONNECTED"
  STATUS_TEXT="Status: Disconnected"
fi

# Update the bar
sketchybar --set $NAME icon="$ICON" label="$CONTEXT_SHORT" icon.color="$ICON_COLOR" label.color="$THEME_SAGE"

# Update popup
sketchybar --set "$NAME" popup.align=center

# Line 1: Full context name
sketchybar --set "$NAME".context label="Context: $CONTEXT" 2>/dev/null || \
  sketchybar --add item "$NAME".context popup."$NAME" \
    --set "$NAME".context label="Context: $CONTEXT" \
      label.font="Iosevka Nerd Font:Regular:13.0" label.color="$THEME_SAGE"

# Line 2: Status
sketchybar --set "$NAME".status label="$STATUS_TEXT" drawing=on 2>/dev/null || \
  sketchybar --add item "$NAME".status popup."$NAME" \
    --set "$NAME".status label="$STATUS_TEXT" \
      label.font="Iosevka Nerd Font:Regular:13.0" label.color="$ICON_COLOR"

# Line 3: API Server (if available)
if [ -n "$API_SERVER" ]; then
  sketchybar --set "$NAME".server label="Server: $API_SERVER" drawing=on 2>/dev/null || \
    sketchybar --add item "$NAME".server popup."$NAME" \
      --set "$NAME".server label="Server: $API_SERVER" \
        label.font="Iosevka Nerd Font:Regular:13.0" label.color="$THEME_LAVENDER"
else
  sketchybar --set "$NAME".server drawing=off 2>/dev/null
fi
