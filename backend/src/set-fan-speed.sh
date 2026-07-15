#!/bin/bash

# This script sets the fan speed for a given fan number.
# It is intended to be called by the victus-control backend service with sudo.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <fan_number> <speed>"
    exit 1
fi

FAN_NUM=$1
SPEED=$2

if ! [[ "$FAN_NUM" =~ ^[0-9]+$ ]]; then
    echo "Error: Fan number must be a positive integer"
    exit 1
fi

if ! [[ "$SPEED" =~ ^[0-9]+$ ]]; then
    echo "Error: Speed must be a positive integer"
    exit 1
fi

HWMON_BASE="/sys/devices/platform/hp-wmi/hwmon"
# Pick the highest-numbered hwmon dir to match the backend's util.cpp selection;
# plain `head -n 1` follows readdir order and can disagree with the C++ side.
HWMON_PATH=$(find "$HWMON_BASE" -mindepth 1 -maxdepth 1 -type d -name "hwmon*" 2>/dev/null | sort -V | tail -n 1 || true)

if [ -z "$HWMON_PATH" ]; then
    echo "Error: Hwmon directory not found."
    exit 1
fi

TARGET_FILE="$HWMON_PATH/fan${FAN_NUM}_target"
if [ ! -e "$TARGET_FILE" ]; then
    echo "Error: Target file does not exist: $TARGET_FILE"
    exit 1
fi

echo "1" > "$HWMON_PATH/pwm1_enable"
echo "$SPEED" | tee "$TARGET_FILE" > /dev/null
