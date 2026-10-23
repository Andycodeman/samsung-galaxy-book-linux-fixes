#!/usr/bin/env bash
#
# install-ov02c10-camera.sh
#
# Full camera + speaker setup for Samsung Galaxy Book4 Ultra (960XGL),
# Meteor Lake + OV02C10, on Ubuntu 26.04.
#
# Tested on: kernel 7.0.0-38-generic, Ubuntu 26.04.
# Result: camera works in Firefox, Brave, Chromium, Teams; speakers work.
#
# Re-runnable. Uses Andycodeman's samsung-galaxy-book-linux-fixes repo
# for the DKMS 26 MHz patch, the libcamera stack, and the speaker fix.
#
set -euo pipefail

REPO_URL="https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes.git"
REPO_DIR="${HOME}/samsung-galaxy-book-linux-fixes"
TARBALL_URL="https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz"

log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

[[ $EUID -ne 0 ]] || die "run as your normal user, not root (the script uses sudo)."

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
log "Checking prerequisites..."
need_cmd sudo
need_cmd curl
need_cmd git
need_cmd dkms
need_cmd make

# ---------------------------------------------------------------------------
# Fetch the repo
# ---------------------------------------------------------------------------
if [[ ! -d "${REPO_DIR}" ]]; then
    log "Cloning ${REPO_URL}"
    git clone "${REPO_URL}" "${REPO_DIR}"
else
    log "Updating existing repo in ${REPO_DIR}"
    git -C "${REPO_DIR}" pull --ff-only || warn "git pull failed; continuing with existing tree"
fi

# ---------------------------------------------------------------------------
# Step 1 — Camera stack (libcamera + 26 MHz DKMS + IVSC + WirePlumber rules)
# ---------------------------------------------------------------------------
log "Step 1: camera stack installer (webcam-fix-libcamera)"
if [[ -x "${REPO_DIR}/webcam-fix-libcamera/install.sh" ]]; then
    ( cd "${REPO_DIR}/webcam-fix-libcamera" && ./install.sh )
else
    warn "webcam-fix-libcamera/install.sh not found; skipping"
fi

# ---------------------------------------------------------------------------
# Step 2 — Permissions: video group + udev rules for IPU6 nodes
# ---------------------------------------------------------------------------
log "Step 2: camera permissions (video group + udev rules)"

if ! id -nG "$USER" | tr ' ' '\n' | grep -qx video; then
    log "Adding ${USER} to the 'video' group (log out / reboot required)"
    sudo usermod -aG video "$USER"
fi

sudo tee /etc/udev/rules.d/99-ipu6-camera.rules >/dev/null <<'EOF'
SUBSYSTEM=="video4linux", GROUP="video", MODE="0660"
SUBSYSTEM=="intel-ipu6-isys", GROUP="video", MODE="0660"
KERNEL=="ipu-psys*", GROUP="video", MODE="0660"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger || true

# ---------------------------------------------------------------------------
# Step 3 — Speaker fix (Book4)
# ---------------------------------------------------------------------------
log "Step 3: speaker fix (speaker-fix)"
if [[ -x "${REPO_DIR}/speaker-fix/install.sh" ]]; then
    ( cd "${REPO_DIR}/speaker-fix" && sudo ./install.sh )
else
    warn "speaker-fix/install.sh not found; skipping"
fi

# ---------------------------------------------------------------------------
# Step 4 — Browser setup
# ---------------------------------------------------------------------------
log "Step 4: browser camera flags"

# Chromium (Snap): connect camera interface + pre-seed portal permission
if snap list chromium >/dev/null 2>&1; then
    log "Configuring Chromium (Snap) camera access"
    sudo snap disconnect chromium:camera 2>/dev/null || true
    sudo snap connect chromium:camera 2>/dev/null || true
    busctl --user call org.freedesktop.impl.portal.PermissionStore \
        /org/freedesktop/impl/portal/PermissionStore \
        org.freedesktop.impl.portal.PermissionStore SetPermission \
        sbssas "devices" true "camera" "chromium" 1 "yes" 2>/dev/null || true
    warn "Enable chrome://flags/#enable-webrtc-pipewire-camera in Chromium and fully restart it."
else
    warn "Chromium Snap not installed; skipping Chromium setup"
fi

# Brave (Snap) camera interface + permission
if snap list brave >/dev/null 2>&1; then
    log "Configuring Brave (Snap) camera access"
    sudo snap connect brave:camera 2>/dev/null || true
    busctl --user call org.freedesktop.impl.portal.PermissionStore \
        /org/freedesktop/impl/portal/PermissionStore \
        org.freedesktop.impl.portal.PermissionStore SetPermission \
        sbssas "devices" true "camera" "com.brave.Browser" 1 "yes" 2>/dev/null || true
    warn "Enable brave://flags/#enable-webrtc-pipewire-camera in Brave and fully restart it."
else
    warn "Brave Snap not installed; skipping Brave setup"
fi

# Firefox (Snap) camera interface
if snap list firefox >/dev/null 2>&1; then
    log "Connecting Firefox (Snap) camera interface"
    sudo snap connect firefox:camera 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Step 5 — Teams for Linux (Snap): config + camera interface
# ---------------------------------------------------------------------------
if snap list teams-for-linux >/dev/null 2>&1; then
    log "Step 5: configuring Teams for Linux (Snap)"

    sudo snap connect teams-for-linux:camera 2>/dev/null || true

    CFG_DIR="${HOME}/snap/teams-for-linux/current/.config/teams-for-linux"
    mkdir -p "${CFG_DIR}"
    if [[ -f "${CFG_DIR}/config.json" ]]; then
        cp "${CFG_DIR}/config.json" "${CFG_DIR}/config.json.bak.$(date +%s)"
    fi
    cat > "${CFG_DIR}/config.json" <<'EOF'
{
    "electronCLIFlags": [
        ["enable-features", "WebRtcPipeWireCamera,WebRTCPipeWireCapturer"]
    ]
}
EOF
    warn "Fully quit Teams (pkill -f teams-for-linux) and relaunch it."
    warn "If the camera still does not appear, use: libcamerify snap run teams-for-linux"
else
    warn "Teams for Linux Snap not installed; skipping Teams setup"
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
log "Verifying..."

if command -v cam >/dev/null 2>&1; then
    if cam -l 2>/dev/null | grep -q "Internal front camera"; then
        log "Camera enumerates: Internal front camera"
    else
        warn "cam -l did not list the camera. A reboot and re-login are required for the video group."
    fi
fi

if command -v aplay >/dev/null 2>&1; then
    if aplay -l 2>/dev/null | grep -qE "card|sof-hda-dsp"; then
        log "Audio: sound card present"
    else
        warn "aplay -l reports no sound card; check firmware-sof-signed and reboot."
    fi
fi

cat <<'EOF'

------------------------------------------------------------------------
Done.

Next steps:
  1. Reboot (required for DKMS module and the video group change).
  2. After reboot, log in again (group changes apply to new sessions).
  3. Verify:
        cam -l
        aplay -l
  4. Enable the PipeWire camera flag in Chromium and Brave:
        chrome://flags/#enable-webrtc-pipewire-camera  -> Enabled
        brave://flags/#enable-webrtc-pipewire-camera   -> Enabled
     Then fully quit and relaunch each browser.
  5. Teams: fully quit and relaunch after the config was written.

If the IPU6 firmware fails at boot:
    intel-ipu6 ...: Direct firmware load for intel/ipu/ipu6epmtl_fw.bin failed

  Add the firmware to the initramfs:
    sudo tee /etc/initramfs-tools/hooks/ipu6-fw >/dev/null <<'HOOK'
    #!/bin/sh
    PREREQ=""
    prereqs() { echo "$PREREQ"; }
    case "$1" in prereqs) prereqs; exit 0 ;; esac
    . /usr/share/initramfs-tools/hook-functions
    copy_file firmware /lib/firmware/intel/ipu/ipu6epmtl_fw.bin.zst
    HOOK
    sudo chmod +x /etc/initramfs-tools/hooks/ipu6-fw
    sudo update-initramfs -u
    sudo reboot

  Or, to recover immediately without a reboot:
    echo 0000:00:05.0 | sudo tee /sys/bus/pci/drivers/intel-ipu6/unbind
    echo 0000:00:05.0 | sudo tee /sys/bus/pci/drivers/intel-ipu6/bind
------------------------------------------------------------------------
EOF