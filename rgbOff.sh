#!/bin/bash
# ------------------------------------------------------------------
# 🌙 rgb-off.sh - Reliable & Silent RGB Off Script
# ------------------------------------------------------------------
# HOW TO INSTALL:
#   1. mkdir -p ~/.local/bin
#   2. nano ~/.local/bin/rgb-off.sh  (Paste this content)
#   3. chmod +x ~/.local/bin/rgb-off.sh
#
# HOW TO RUN:
#   ~/.local/bin/rgb-off.sh          (Silent, ~25s duration)
#   ~/.local/bin/rgb-off.sh --debug  (Shows logs)
# ------------------------------------------------------------------

DEBUG=false
[[ "$1" == "--debug" || "$1" == "-d" ]] && DEBUG=true

# Helper for logging
log() { $DEBUG && echo "$1"; }

log "🌙 RGB Off Script Starting..."

# 1. SCAN DEVICES (SILENTLY)
# Redirect stderr (2>/dev/null) to hide i2c warnings
log "→ Scanning devices..."
DEVICES=$(openrgb --noautoconnect --list-devices 2>/dev/null)

# Helper to find ID by name
get_id() {
    echo "$DEVICES" | grep -E "^[0-9]+:.*$1" | head -1 | cut -d: -f1
}

# Helper to turn off a single device
turn_off() {
    local id="$1"
    local mode="$2"
    local name="$3"

    if [[ -z "$id" ]]; then
        log "  ⚠ $name not found, skipping"
        return
    fi

    log "  → $name (device $id) [$mode]..."

    # We explicitly redirect both stdout and stderr to /dev/null for silence
    if [[ "$mode" == "Off" ]]; then
        openrgb --noautoconnect -d "$id" -m Off >/dev/null 2>&1
    else
        openrgb --noautoconnect -d "$id" -m Direct -c 000000 >/dev/null 2>&1
    fi
}

# 2. TURN OFF DEVICES (One by one for maximum reliability)

# --- Devices supporting 'Off' mode ---
turn_off "$(get_id 'ENE DRAM')" "Off" "ENE DRAM 1"
# Second ENE stick
turn_off "$(echo "$DEVICES" | grep -E "^[0-9]+:.*ENE DRAM" | tail -1 | cut -d: -f1)" "Off" "ENE DRAM 2"
turn_off "$(get_id 'ASUS.*7900')" "Off" "ASUS GPU"
turn_off "$(get_id 'LG.*Monitor')" "Off" "LG Monitor"

# --- Devices needing 'Direct' mode + Black ---
turn_off "$(get_id 'MSI MAG')" "Direct" "MSI Motherboard"
turn_off "$(get_id 'NZXT RGB & Fan')" "Direct" "NZXT RGB & Fan"
turn_off "$(get_id 'NZXT RGB Controller')" "Direct" "NZXT RGB Controller"

log "✅ Done!"
exit 0
