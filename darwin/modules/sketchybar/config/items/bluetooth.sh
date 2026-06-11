#!/usr/bin/env sh
BLUETOOTH_ICON=""

# Check if SwitchAudioSource CLI is installed
if ! command -v blueutil &> /dev/null; then
    sketchybar --set $NAME icon="$BLUETOOTH_ICON" label="Err" --set '/bluetooth.*/' drawing=on
    exit 1
fi

POWER=$(blueutil --power)

if [ $POWER -eq 0 ]; then
  sketchybar --set $NAME icon="$BLUETOOTH_ICON" label="Off" --set '/bluetooth.*/' drawing=on
else
  CONNECTED=$(blueutil --connected --format json | /etc/profiles/per-user/mattias/bin/jq length)
  sketchybar --set $NAME icon="$BLUETOOTH_ICON" label="$CONNECTED" --set '/bluetooth.*/' drawing=on
fi
