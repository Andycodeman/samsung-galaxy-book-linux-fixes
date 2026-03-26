#!/bin/bash
# tune-ccm.sh — Interactive CCM tuning tool for libcamera cameras
# Cycles through color correction presets with live preview.
#
# Usage: ./tune-ccm.sh [sensor]
#   sensor: ov02c10 (default) or ov02e10
#
# Preview modes (auto-detected):
#   - Camera relay: restarts relay service, opens GStreamer viewer on /dev/video0
#   - Direct qcam: uses qcam for direct libcamera access (no relay needed)
#
# Requires: sudo access to write tuning files

set -e

SENSOR="${1:-ov02c10}"

# Find the tuning file location
TUNING_FILE=""
for dir in /usr/local/share/libcamera/ipa/simple \
           /usr/share/libcamera/ipa/simple; do
    if [[ -d "$dir" ]]; then
        TUNING_FILE="$dir/${SENSOR}.yaml"
        break
    fi
done

if [[ -z "$TUNING_FILE" ]]; then
    echo "ERROR: Could not find libcamera IPA data directory."
    echo "Make sure libcamera is installed."
    exit 1
fi

# Detect preview mode: relay service or qcam
USE_RELAY=false
VIEWER_PID=""
if systemctl --user is-active camera-relay.service >/dev/null 2>&1; then
    USE_RELAY=true
    echo "  Detected camera-relay service — will restart relay for each preset."
elif command -v qcam >/dev/null 2>&1; then
    echo "  No camera-relay — will use qcam for direct preview."
else
    echo "ERROR: No camera-relay service running and qcam not found."
    echo "Start the relay:  systemctl --user start camera-relay.service"
    echo "Or install qcam:  sudo apt install libcamera-tools"
    exit 1
fi

# Export IPA path in case it's a source build
for dir in /usr/local/lib/*/libcamera/ipa /usr/local/lib/libcamera/ipa \
           /usr/lib/*/libcamera/ipa /usr/lib/libcamera/ipa; do
    if [[ -d "$dir" ]]; then
        export LIBCAMERA_IPA_MODULE_PATH="$dir"
        break
    fi
done

# Detect libcamera version for Lut vs Adjust algorithm
# v0.5.x uses Lut; v0.6+ uses Adjust (replaces Lut)
USE_LUT=false
LIBCAMERA_VER=$(ls -l /usr/local/lib/*/libcamera.so.* /usr/local/lib/libcamera.so.* \
    /usr/lib64/libcamera.so.* /usr/lib/*/libcamera.so.* /usr/lib/libcamera.so.* 2>/dev/null \
    | grep -oP 'libcamera\.so\.\K[0-9]+\.[0-9]+' | head -1 || true)
if [[ -n "$LIBCAMERA_VER" ]]; then
    LIBCAMERA_MINOR=$(echo "$LIBCAMERA_VER" | cut -d. -f2)
    if [[ "$LIBCAMERA_MINOR" -lt 6 ]] 2>/dev/null; then
        USE_LUT=true
        echo "  libcamera ${LIBCAMERA_VER} detected — using Lut (not Adjust)"
    fi
fi

# Back up the current tuning file
BACKUP=""
if [[ -f "$TUNING_FILE" ]]; then
    BACKUP="${TUNING_FILE}.bak.$$"
    sudo cp "$TUNING_FILE" "$BACKUP"
fi

cleanup() {
    # Kill viewer if we started it
    if [[ -n "$VIEWER_PID" ]] && kill -0 "$VIEWER_PID" 2>/dev/null; then
        kill "$VIEWER_PID" 2>/dev/null
        wait "$VIEWER_PID" 2>/dev/null || true
    fi
    # Restore backup if user didn't explicitly save (Ctrl+C, error, etc.)
    if [[ $SELECTED -lt 0 && -n "$BACKUP" && -f "$BACKUP" ]]; then
        sudo cp "$BACKUP" "$TUNING_FILE"
        sudo rm -f "$BACKUP"
        echo ""
        echo "  Interrupted — restored original tuning file."
        if $USE_RELAY; then
            echo "  Restarting relay with original tuning..."
            systemctl --user restart camera-relay.service 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT INT TERM

# ─── CCM Presets ───────────────────────────────────────────────
# Each preset: NAME|DESCRIPTION|YAML_CONTENT
# Rows should sum to ~1.0 to preserve neutral greys.
#
# Presets are organized:
#   1-3:   Baselines (no CCM, identity, current installed)
#   4-7:   Anti-green (suppress green tint — the main Book4 issue)
#   8-10:  Green suppress + warm (counter green + add warmth)
#   11-13: Symmetric saturation boosts
#   14-16: Anti-purple / green boost (for Book5 / OV02E10)
#   17-18: Reference matrices (Arch Wiki, OV2740 community)
PRESETS=(
"No CCM (raw baseline)|No color correction — raw debayer + AWB only. Very desaturated.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Adjust:
  - Agc:
..."

"Identity CCM|Identity matrix — CCM pipeline active but no color change.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.0, 0.0, 0.0,
                 0.0, 1.0, 0.0,
                 0.0, 0.0, 1.0 ]
  - Adjust:
  - Agc:
..."

"Current installed|Your currently installed CCM (OV2740 community matrix).|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 3200
          ccm: [  1.44, -0.12, -0.08,
                 -0.10,  1.62, -0.25,
                 -0.05, -0.28,  1.6 ]
        - ct: 4000
          ccm: [  1.38, -0.10, -0.05,
                 -0.15,  1.6, -0.10,
                 -0.15, -0.15,  1.56 ]
        - ct: 6500
          ccm: [  1.4, -0.04, -0.06,
                  0,     0.61,  0.1,
                 -0.02, -0.2,   1.2 ]
  - Adjust:
  - Agc:
..."

"Anti-green light|Reduces green 10%. Subtle green tint correction.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.1,  0.0, -0.1,
                 0.05, 0.9,  0.05,
                -0.1,  0.0,  1.1 ]
  - Adjust:
  - Agc:
..."

"Anti-green medium|Reduces green 20%, boosts R+B. Moderate green tint fix.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.2,  0.0, -0.2,
                 0.1,  0.8,  0.1,
                -0.2,  0.0,  1.2 ]
  - Adjust:
  - Agc:
..."

"Anti-green strong|Reduces green 30%, strong R+B boost. For heavy green cast.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.3,  0.0, -0.3,
                 0.15, 0.7,  0.15,
                -0.3,  0.0,  1.3 ]
  - Adjust:
  - Agc:
..."

"Anti-green + saturation|Reduces green, adds overall saturation boost.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.3, -0.1, -0.2,
                 0.0,  0.85, 0.15,
                -0.2, -0.1,  1.3 ]
  - Adjust:
  - Agc:
..."

"Warm anti-green light|Reduces green, shifts slightly warm. Counters cool green cast.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.15, -0.05, -0.1,
                 0.05,  0.9,   0.05,
                -0.15, -0.05,  1.2 ]
  - Adjust:
  - Agc:
..."

"Warm anti-green medium|Stronger warm shift + green reduction. Good for fluorescent lighting.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.25, -0.1, -0.15,
                 0.1,   0.8,  0.1,
                -0.2,  -0.1,  1.3 ]
  - Adjust:
  - Agc:
..."

"Warm anti-green strong|Heavy warm shift + green suppression. For very green/cool scenes.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.35, -0.15, -0.2,
                 0.15,  0.7,   0.15,
                -0.25, -0.15,  1.4 ]
  - Adjust:
  - Agc:
..."

"Symmetric light boost|Equal 10% saturation boost on all channels. Mild color pop.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.1, -0.05, -0.05,
                -0.05,  1.1, -0.05,
                -0.05, -0.05,  1.1 ]
  - Adjust:
  - Agc:
..."

"Symmetric medium boost|Equal 20% saturation boost. Stronger color pop.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.2, -0.1, -0.1,
                -0.1,  1.2, -0.1,
                -0.1, -0.1,  1.2 ]
  - Adjust:
  - Agc:
..."

"Symmetric strong boost|Equal 40% saturation boost. Very vivid colors.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.4, -0.2, -0.2,
                -0.2,  1.4, -0.2,
                -0.2, -0.2,  1.4 ]
  - Adjust:
  - Agc:
..."

"Green boost (anti-purple) light|Boosts green, reduces R+B. For purple/magenta cast.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.05, -0.025, -0.025,
                -0.1,   1.3,   -0.2,
                -0.025, -0.025,  1.05 ]
  - Adjust:
  - Agc:
..."

"Green boost (anti-purple) medium|Boosts green strongly. For moderate purple cast.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.0,  0.0,  0.0,
                -0.2,  1.4, -0.2,
                 0.0,  0.0,  1.0 ]
  - Adjust:
  - Agc:
..."

"Green boost (anti-purple) strong|Boosts green heavily. For strong purple bias.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 0.95,  0.025, 0.025,
                -0.25,  1.5,  -0.25,
                 0.025, 0.025, 0.95 ]
  - Adjust:
  - Agc:
..."

"Arch Wiki OV02C10|Original Arch Wiki matrix for OV02C10. Conservative, natural.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.05, -0.02, -0.01,
                -0.03,  0.92, -0.03,
                -0.01, -0.02,  1.05 ]
  - Adjust:
  - Agc:
..."

"OV2740 community (current default)|Strong matrix from OV2740 tuning. Your current installed default.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 6500
          ccm: [ 2.25, -1.00, -0.25,
                -0.45,  1.35, -0.20,
                 0.00, -0.60,  1.60 ]
  - Adjust:
  - Agc:
..."
)

# ─── Main loop ─────────────────────────────────────────────────
TOTAL=${#PRESETS[@]}
CURRENT=0
SELECTED=-1

echo "=============================================="
echo "  Camera CCM Tuning Tool"
echo "=============================================="
echo ""
echo "  Sensor:  $SENSOR"
echo "  File:    $TUNING_FILE"
echo "  Presets: $TOTAL"
if $USE_RELAY; then
    echo "  Mode:    Camera relay (restart service + GStreamer viewer)"
else
    echo "  Mode:    Direct qcam"
fi
echo ""
echo "  Controls:"
echo "    Enter / n  ->  Next preset"
echo "    p          ->  Previous preset"
echo "    s          ->  Save current preset and exit"
echo "    q          ->  Quit without saving (restores backup)"
echo "    number     ->  Jump to preset (1-${TOTAL})"
echo ""
echo "  The camera will restart for each preset (takes a few seconds)."
echo "  Keep the preview window visible."
echo ""
read -r -p "Press Enter to start..." _

start_viewer() {
    if [[ -n "$VIEWER_PID" ]] && kill -0 "$VIEWER_PID" 2>/dev/null; then
        return
    fi
    if $USE_RELAY; then
        gst-launch-1.0 pipewiresrc ! videoconvert ! autovideosink 2>/dev/null &
        VIEWER_PID=$!
    fi
}

kill_viewer() {
    if [[ -n "$VIEWER_PID" ]] && kill -0 "$VIEWER_PID" 2>/dev/null; then
        kill "$VIEWER_PID" 2>/dev/null
        wait "$VIEWER_PID" 2>/dev/null || true
        VIEWER_PID=""
    fi
}

apply_preset() {
    local idx=$1
    local entry="${PRESETS[$idx]}"
    # Extract fields using parameter expansion (read only handles one line)
    local name="${entry%%|*}"
    local rest="${entry#*|}"
    local desc="${rest%%|*}"
    local yaml="${rest#*|}"

    echo ""
    echo "----------------------------------------------"
    echo "  [$((idx+1))/$TOTAL] $name"
    echo "  $desc"
    echo "----------------------------------------------"

    # Write tuning file (swap Adjust/Lut based on libcamera version)
    if [[ "$USE_LUT" == "true" ]]; then
        echo "$yaml" | sed 's/^  - Adjust:/  - Lut:/' | sudo tee "$TUNING_FILE" > /dev/null
    else
        echo "$yaml" | sudo tee "$TUNING_FILE" > /dev/null
    fi
    sync  # ensure file is flushed to disk

    if $USE_RELAY; then
        # Kill viewer so it's not holding the device during restart
        kill_viewer
        # Restart camera relay to pick up new tuning file
        systemctl --user restart camera-relay.service
        sleep 2
        # Start fresh viewer
        start_viewer
    else
        # Kill and restart qcam
        kill_viewer
        qcam &
        VIEWER_PID=$!
        sleep 3
    fi
}

apply_preset $CURRENT

while true; do
    echo ""
    read -r -p "  [$((CURRENT+1))/${TOTAL}] Next(Enter/n) Prev(p) Save(s) Quit(q) Jump(1-${TOTAL}): " choice

    case "$choice" in
        ""| n | N)
            CURRENT=$(( (CURRENT + 1) % TOTAL ))
            apply_preset $CURRENT
            ;;
        p | P)
            CURRENT=$(( (CURRENT - 1 + TOTAL) % TOTAL ))
            apply_preset $CURRENT
            ;;
        s | S)
            SELECTED=$CURRENT
            break
            ;;
        q | Q)
            break
            ;;
        [0-9]*)
            if [[ "$choice" -ge 1 && "$choice" -le $TOTAL ]] 2>/dev/null; then
                CURRENT=$((choice - 1))
                apply_preset $CURRENT
            else
                echo "  Invalid number. Enter 1-${TOTAL}."
            fi
            ;;
        *)
            echo "  Unknown command: $choice"
            ;;
    esac
done

# Kill viewer
kill_viewer

echo ""
if [[ $SELECTED -ge 0 ]]; then
    name="${PRESETS[$SELECTED]%%|*}"
    echo "=============================================="
    echo "  Saved: $name"
    echo "  File:  $TUNING_FILE"
    echo "=============================================="
    echo ""
    if $USE_RELAY; then
        echo "  Restarting relay with saved preset..."
        systemctl --user restart camera-relay.service
    else
        echo "  Restart PipeWire to apply for all apps:"
        echo "    systemctl --user restart pipewire wireplumber"
    fi
    # Remove backup
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        sudo rm -f "$BACKUP"
    fi
else
    # Restore backup
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        sudo cp "$BACKUP" "$TUNING_FILE"
        sudo rm -f "$BACKUP"
        echo "  Restored original tuning file."
        if $USE_RELAY; then
            echo "  Restarting relay with original tuning..."
            systemctl --user restart camera-relay.service
        fi
    fi
    echo "  Exited without saving."
fi
