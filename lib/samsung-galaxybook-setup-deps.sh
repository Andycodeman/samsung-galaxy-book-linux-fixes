#!/bin/bash
# =============================================================================
# Samsung Galaxy Book — Dependency Setup Helper
# Run via pkexec from samsung-galaxybook-gui — never call directly.
# Handles all first-time setup in a single elevated session.
#
# Args: <ID_LOWER> <ID_LIKE_LOWER> <NEED_GTK> <NEED_INTER> <NEED_POLICY>
#       <POLICY_SRC> <POLICY_DST>
# =============================================================================

set -e

ID_LOWER="$1"
ID_LIKE_LOWER="$2"
NEED_GTK="$3"
NEED_INTER="$4"
NEED_POLICY="$5"
POLICY_SRC="$6"
POLICY_DST="$7"

# ── Identify the logged-in desktop user (for notifications) ──────────────────
USER_NAME=$(loginctl list-sessions --no-legend 2>/dev/null \
    | awk '$4 == "seat0" {print $3}' | head -1)
USER_ID=$(id -u "$USER_NAME" 2>/dev/null)
DBUS_ADDR="unix:path=/run/user/${USER_ID}/bus"

notify_error() {
    local msg="$1"
    if [[ -n "$USER_NAME" ]] && which notify-send >/dev/null 2>&1; then
        sudo -u "$USER_NAME" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            notify-send --icon="dialog-error" --urgency=critical \
            "Samsung Galaxy Book — Setup Error" "$msg" 2>/dev/null || true
    fi
}

FAILED_DEPS=()

# ── GTK python bindings ───────────────────────────────────────────────────────
if [[ "$NEED_GTK" == true ]]; then
    echo "Installing GTK Python bindings..."
    GTK_OK=true
    if [[ "$ID_LOWER" == "fedora" ]]; then
        dnf install -y python3-gobject python3-cairo || GTK_OK=false
    elif [[ "$ID_LOWER" == "ubuntu" || "$ID_LIKE_LOWER" == *"ubuntu"* \
         || "$ID_LOWER" == "debian" || "$ID_LIKE_LOWER" == *"debian"* ]]; then
        apt-get install -y python3-gi python3-gi-cairo python3-cairo gir1.2-gtk-3.0 || GTK_OK=false
    elif [[ "$ID_LOWER" == "arch" || "$ID_LIKE_LOWER" == *"arch"* ]]; then
        pacman -S --noconfirm --needed python-gobject python-cairo || GTK_OK=false
    fi
    if [[ "$GTK_OK" == true ]]; then
        echo "GTK bindings installed."
    else
        FAILED_DEPS+=("GTK Python bindings (python3-gobject)")
    fi
fi

# ── Inter font (best-effort) ──────────────────────────────────────────────────
if [[ "$NEED_INTER" == true ]]; then
    echo "Installing Inter font..."
    INTER_OK=true
    if [[ "$ID_LOWER" == "fedora" ]]; then
        dnf install -y rsms-inter-fonts || INTER_OK=false
    elif [[ "$ID_LOWER" == "ubuntu" || "$ID_LIKE_LOWER" == *"ubuntu"* \
         || "$ID_LOWER" == "debian" || "$ID_LIKE_LOWER" == *"debian"* ]]; then
        apt-get install -y fonts-inter || INTER_OK=false
    elif [[ "$ID_LOWER" == "arch" || "$ID_LIKE_LOWER" == *"arch"* ]]; then
        pacman -S --noconfirm --needed inter-font || INTER_OK=false
    fi
    if [[ "$INTER_OK" == true ]]; then
        fc-cache -f || true
        echo "Inter font installed."
    else
        # Inter is best-effort — note it but don't add to FAILED_DEPS
        echo "Inter font install failed — continuing without it."
    fi
fi

# ── Polkit policy file ────────────────────────────────────────────────────────
if [[ "$NEED_POLICY" == true ]]; then
    echo "Installing polkit policy..."
    if cp "$POLICY_SRC" "$POLICY_DST"; then
        echo "Polkit policy installed."
    else
        FAILED_DEPS+=("Polkit policy file")
    fi
fi

# ── Report any failures and exit ──────────────────────────────────────────────
if [[ ${#FAILED_DEPS[@]} -gt 0 ]]; then
    MSG="The following required dependencies could not be installed:\n"
    for dep in "${FAILED_DEPS[@]}"; do
        MSG+="  • ${dep}\n"
    done
    MSG+="Please install them manually and try again."
    echo -e "$MSG"
    notify_error "$(echo -e "$MSG")"
    exit 1
fi
