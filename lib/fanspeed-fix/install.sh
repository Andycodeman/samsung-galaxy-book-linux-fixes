#!/bin/bash
# =============================================================================
# Samsung Galaxy Book — Fan Speed Fix — Install
# =============================================================================
# Self-contained. Run as root: sudo bash install.sh
# =============================================================================

set -e

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Please run as root: sudo bash install.sh"
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BLUE}══ $* ${NC}"; }

# ── Distro / initramfs detection ──────────────────────────────────────────────
detect_distro() {
    [[ -f /etc/os-release ]] || error "Cannot detect distro — /etc/os-release not found"
    source /etc/os-release
    local id="${ID,,}" like="${ID_LIKE:-}"; like="${like,,}"
    if [[ "$id" == "fedora" ]]; then DISTRO="fedora"
    elif [[ "$id" == "ubuntu" || "$like" == *"ubuntu"* || "$id" == "debian" || "$like" == *"debian"* ]]; then DISTRO="ubuntu"
    elif [[ "$id" == "arch" || "$like" == *"arch"* ]]; then DISTRO="arch"
    else error "Unsupported distro: $PRETTY_NAME"
    fi

    if [[ "$DISTRO" == "arch" ]]; then
        INITRAMFS_TOOL="mkinitcpio"
    elif command -v dracut &>/dev/null && ! command -v update-initramfs &>/dev/null; then
        INITRAMFS_TOOL="dracut"
    elif command -v update-initramfs &>/dev/null; then
        INITRAMFS_TOOL="initramfs-tools"
    elif command -v dracut &>/dev/null; then
        INITRAMFS_TOOL="dracut"
    else
        error "Could not detect initramfs tool"
    fi
}

set_dsdt_paths() {
    if [[ "$INITRAMFS_TOOL" == "initramfs-tools" ]]; then
        DSDT_OVERRIDE_DIR="/etc/initramfs-tools"
        DSDT_OVERRIDE_AML="${DSDT_OVERRIDE_DIR}/DSDT.aml"
        DSDT_DRACUT_CONF=""
        DSDT_MKINITCPIO_HOOK=""; DSDT_MKINITCPIO_INSTALL=""; DSDT_MKINITCPIO_CONF=""
    elif [[ "$INITRAMFS_TOOL" == "mkinitcpio" ]]; then
        DSDT_OVERRIDE_DIR="/etc/acpi_override"
        DSDT_OVERRIDE_AML="${DSDT_OVERRIDE_DIR}/dsdt_fixed.aml"
        DSDT_DRACUT_CONF=""
        DSDT_MKINITCPIO_HOOK="/etc/initcpio/hooks/acpi_override"
        DSDT_MKINITCPIO_INSTALL="/etc/initcpio/install/acpi_override"
        DSDT_MKINITCPIO_CONF="/etc/mkinitcpio.conf.d/acpi_override.conf"
    else
        DSDT_OVERRIDE_DIR="/etc/acpi_override"
        DSDT_OVERRIDE_AML="${DSDT_OVERRIDE_DIR}/dsdt_fixed.aml"
        DSDT_DRACUT_CONF="/etc/dracut.conf.d/acpi.conf"
        DSDT_MKINITCPIO_HOOK=""; DSDT_MKINITCPIO_INSTALL=""; DSDT_MKINITCPIO_CONF=""
    fi
    DSDT_WORK_DIR="/tmp/dsdt_fixed"
    DSDT_DSL="${DSDT_WORK_DIR}/dsdt_fixed.dsl"
    DSDT_AML_SRC="${DSDT_WORK_DIR}/dsdt_fixed.aml"
}



# ── Install ───────────────────────────────────────────────────────────────────
detect_distro
set_dsdt_paths
KVER=$(uname -r)

FAN_MONITOR_SVC="samsung-galaxybook-fan-monitor.service"
FAN_CHECK_SCRIPT="/usr/local/bin/samsung-galaxybook-fan-monitor.sh"
FAN_CLEANUP="/usr/local/bin/samsung-galaxybook-fan-cleanup.sh"

echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Installing: Fan Speed Fix                     ║"
echo "╚════════════════════════════════════════════════════════════╝"

step "Fan Step 1: Verifying prerequisites"
_sb_locked=false
command -v mokutil &>/dev/null && \
    mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled" && _sb_locked=true
$_sb_locked && error "Secure Boot is enabled — fan speed fix requires Secure Boot to be disabled"
info "✓ Secure Boot is disabled"

step "Fan Step 2: Installing dependencies"
if ! command -v iasl &>/dev/null; then
    info "Installing acpica-tools..."
    if [[ "$DISTRO" == "ubuntu" ]]; then
        apt-get install -y acpica-tools || error "Failed to install acpica-tools"
        dpkg -l acpi-override-initramfs &>/dev/null || \
            apt-get install -y acpi-override-initramfs || error "Failed to install acpi-override-initramfs"
    elif [[ "$DISTRO" == "arch" ]]; then
        pacman -S --noconfirm --needed acpica || error "Failed to install acpica"
    else
        dnf install -y acpica-tools || error "Failed to install acpica-tools"
    fi
fi
info "✓ iasl: $(iasl -v 2>&1 | head -1)"

mkdir -p "$DSDT_WORK_DIR"

step "Fan Step 3: Extracting firmware DSDT"
DSDT_FIRMWARE_SIZE=$(cat /sys/firmware/acpi/tables/DSDT 2>/dev/null | wc -c)
cat /sys/firmware/acpi/tables/DSDT > "${DSDT_WORK_DIR}/dsdt_live.aml"
info "Extracted DSDT ($DSDT_FIRMWARE_SIZE bytes)"

step "Fan Step 4: Decompiling DSDT"
cd "$DSDT_WORK_DIR"
iasl -d "${DSDT_WORK_DIR}/dsdt_live.aml" 2>/dev/null
mv "${DSDT_WORK_DIR}/dsdt_live.dsl" "$DSDT_DSL"
info "Decompiled to $DSDT_DSL"

step "Fan Step 5: Verifying DSDT structure"
grep -q 'Method (_FST' "$DSDT_DSL" \
    || error "_FST method not found — this device may not need this fix"
grep -q 'Name (FANT' "$DSDT_DSL" \
    || error "FANT speed table not found — unsupported device layout"
grep -q 'SFST \[One\] = Local0' "$DSDT_DSL" \
    || warn "_FST may already be patched or uses a different structure"
info "✓ DSDT structure looks compatible"

step "Fan Step 6: Patching _FST method dynamically"
python3 << 'PYEOF'
import re, sys
DSL = "/tmp/dsdt_fixed/dsdt_fixed.dsl"
with open(DSL, 'r') as f:
    content = f.read()
fst_pattern = re.compile(
    r'([ \t]+Method \(_FST, 0, Serialized\)[^\{]*\{[ \t]*\n)'
    r'([ \t]*Local0 = [^\n]+\n)'
    r'.*?'
    r'([ \t]*Return \(SFST\)[^\n]*\n[ \t]*\})',
    re.DOTALL
)
match = fst_pattern.search(content)
if not match:
    print("ERROR: Could not locate _FST method body", file=sys.stderr); sys.exit(1)
indent = "            "
local0_assign = match.group(2).rstrip()
lines = [
    match.group(1).rstrip(),
    f"{indent}// Patched: preserve EC path, evaluate FANT dynamically via Local2",
    f"{local0_assign}",
    f"{indent}If ((Local0 == Zero))",
    f"{indent}{{",
    f"{indent}    Return (Package (0x03) {{ Zero, Zero, Zero }})",
    f"{indent}}}",
    f"{indent}Local0 -= One",
    f"{indent}If ((Local0 >= SizeOf (FANT)))",
    f"{indent}{{",
    f"{indent}    Local0 = (SizeOf (FANT) - One)",
    f"{indent}}}",
    f"{indent}Local1 = ToInteger (DerefOf (FANT [Local0]))",
    f"{indent}If ((Local1 > Zero))",
    f"{indent}{{",
    f"{indent}    Local1 += 0x0A",
    f"{indent}}}",
    f"{indent}Local2 = Package (0x03) {{ Zero, Zero, Zero }}",
    f"{indent}Local2 [One] = Local0",
    f"{indent}Local2 [0x02] = Local1",
    f"{indent}Return (Local2)",
    f"{indent}}}"
]
new_content = fst_pattern.sub("\n".join(lines), content, count=1)
if new_content == content:
    print("ERROR: Replacement made no change", file=sys.stderr); sys.exit(1)
rev_pattern = re.compile(r'(DefinitionBlock\s*\("",\s*"DSDT",\s*\d+,\s*"\w+",\s*"\w+",\s*)(0x[0-9A-Fa-f]+)(\))')
rev_match = rev_pattern.search(new_content)
if not rev_match:
    print("ERROR: Could not find OEM revision", file=sys.stderr); sys.exit(1)
old_rev = int(rev_match.group(2), 16)
new_rev_str = "0x{:08X}".format(old_rev + 1)
new_content = rev_pattern.sub(r'\g<1>' + new_rev_str + r'\g<3>', new_content, count=1)
print(f"OEM revision bumped: 0x{old_rev:08X} -> {new_rev_str}")
with open(DSL, 'w') as f:
    f.write(new_content)
print("Patch applied: dynamic ASL array indexing")
PYEOF
info "_FST method patched"

step "Fan Step 7: Compiling patched DSDT"
cd "$DSDT_WORK_DIR"
iasl -tc -f "$DSDT_DSL" 2>/dev/null || error "iasl compilation failed"
[[ -f "$DSDT_AML_SRC" ]] || error "Compiled AML not found at $DSDT_AML_SRC"
info "Compiled: $(wc -c < "$DSDT_AML_SRC") bytes"

step "Fan Step 8: Installing ACPI override"
mkdir -p "$DSDT_OVERRIDE_DIR"
cp "$DSDT_AML_SRC" "$DSDT_OVERRIDE_AML"
info "Installed to $DSDT_OVERRIDE_AML"

step "Fan Step 9: Configuring initramfs"
if [[ "$INITRAMFS_TOOL" == "mkinitcpio" ]]; then
    mkdir -p /etc/initcpio/hooks /etc/initcpio/install
    cat > "$DSDT_MKINITCPIO_HOOK" << 'EOF'
#!/usr/bin/ash
run_hook() { : ; }
EOF
    cat > "$DSDT_MKINITCPIO_INSTALL" << 'EOF'
#!/bin/bash
build() {
    for _aml in /etc/acpi_override/*.aml; do
        [[ -f "$_aml" ]] || continue
        _name=$(basename "$_aml")
        if [[ "$_name" == "DSDT.aml" || "$_name" == "dsdt_fixed.aml" ]]; then
            add_file "$_aml" "/DSDT.aml"
        else
            add_file "$_aml" "/kernel/firmware/acpi/${_name}"
        fi
    done
}
EOF
    mkdir -p "$(dirname "$DSDT_MKINITCPIO_CONF")"
    EXISTING_HOOKS=$(grep '^HOOKS=' /etc/mkinitcpio.conf 2>/dev/null | head -1)
    if [[ -n "$EXISTING_HOOKS" ]] && ! echo "$EXISTING_HOOKS" | grep -q "acpi_override"; then
        cat > "$DSDT_MKINITCPIO_CONF" << EOF
# Samsung Galaxy Book fan speed fix — insert DSDT override hook
$(echo "$EXISTING_HOOKS" | sed 's/\bbase\b/base acpi_override/')
EOF
    else
        echo "HOOKS=(base acpi_override udev autodetect modconf block filesystems keyboard fsck)" \
            > "$DSDT_MKINITCPIO_CONF"
    fi
elif [[ "$INITRAMFS_TOOL" == "dracut" ]]; then
    cat > "$DSDT_DRACUT_CONF" << 'EOF'
# Samsung Galaxy Book fan speed fix
acpi_override=yes
acpi_table_dir="/etc/acpi_override"
EOF
    info "Dracut config written to $DSDT_DRACUT_CONF"
else
    info "initramfs-tools: DSDT.aml placed in $DSDT_OVERRIDE_DIR"
fi

step "Fan Step 10: Storing patched DSDT hash for change detection"
mkdir -p /var/lib/samsung-galaxybook
sha256sum "$DSDT_OVERRIDE_AML" | awk '{print $1}' \
    > /var/lib/samsung-galaxybook/dsdt-firmware.sha256
chmod 644 /var/lib/samsung-galaxybook/dsdt-firmware.sha256
info "Hash stored: $(cat /var/lib/samsung-galaxybook/dsdt-firmware.sha256)"

step "Fan Step 11: Installing fan monitor service"
cat > "$FAN_CLEANUP" << FANCLEANEOF
#!/bin/bash
# Samsung Galaxy Book — remove DSDT fan override (runs as root)
KVER=\$(uname -r)
rm -f "${DSDT_OVERRIDE_AML}"
[[ -n "${DSDT_DRACUT_CONF}" ]]          && rm -f "${DSDT_DRACUT_CONF}"
[[ -n "${DSDT_MKINITCPIO_HOOK}" ]]      && rm -f "${DSDT_MKINITCPIO_HOOK}"
[[ -n "${DSDT_MKINITCPIO_INSTALL}" ]]   && rm -f "${DSDT_MKINITCPIO_INSTALL}"
[[ -n "${DSDT_MKINITCPIO_CONF}" ]]      && rm -f "${DSDT_MKINITCPIO_CONF}"
rm -f /var/lib/samsung-galaxybook/dsdt-firmware.sha256
systemctl disable ${FAN_MONITOR_SVC} 2>/dev/null || true
rm -f /etc/systemd/system/${FAN_MONITOR_SVC}
systemctl daemon-reload 2>/dev/null || true
rm -f ${FAN_CHECK_SCRIPT}
if [[ "${INITRAMFS_TOOL}" == "mkinitcpio" ]]; then
    mkinitcpio -P
elif [[ "${INITRAMFS_TOOL}" == "dracut" ]]; then
    dracut --force "/boot/initramfs-\${KVER}.img" "\${KVER}"
else
    update-initramfs -u -k "\${KVER}"
fi
rm -f ${FAN_CLEANUP}
FANCLEANEOF
chmod 750 "$FAN_CLEANUP"

cat > "$FAN_CHECK_SCRIPT" << 'FANCHECKEOF'
#!/bin/bash
# Samsung Galaxy Book — fan DSDT fix monitor (system service, runs as root)
FAN_CLEANUP="/usr/local/bin/samsung-galaxybook-fan-cleanup.sh"
DSDT_FIRMWARE_HASH="/var/lib/samsung-galaxybook/dsdt-firmware.sha256"
DSDT_OVERRIDE_AML="__DSDT_OVERRIDE_AML__"

notify_user() {
    local title="$1" msg="$2" type="$3"
    local USER_NAME USER_ID
    USER_NAME=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" {print $3}' | head -1)
    USER_ID=$(id -u "$USER_NAME" 2>/dev/null)
    if [[ -n "$USER_ID" ]]; then
        local QDBUS=""
        pgrep -u "$USER_NAME" plasmashell >/dev/null 2>&1 && {
            command -v qdbus-qt6 &>/dev/null && QDBUS="qdbus-qt6"
            [[ -z "$QDBUS" ]] && command -v qdbus6 &>/dev/null && QDBUS="qdbus6"
        }
        if [[ -n "$QDBUS" ]]; then
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_ID}/bus" \
                "$QDBUS" org.kde.plasmashell /org/kde/osdService \
                org.kde.osdService.showText "dialog-information" "$title: $msg" 2>/dev/null || true
        else
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_ID}/bus" \
                notify-send "$title" "$msg" 2>/dev/null || true
        fi
    else
        logger -t samsung-galaxybook-monitor "$title: $msg"
    fi
}

if [[ -f "$DSDT_FIRMWARE_HASH" ]] && [[ -f "$DSDT_OVERRIDE_AML" ]]; then
    CURRENT_DSDT_HASH=$(sha256sum /sys/firmware/acpi/tables/DSDT | awk '{print $1}')
    STORED_DSDT_HASH=$(cat "$DSDT_FIRMWARE_HASH")
    if [[ "$CURRENT_DSDT_HASH" != "$STORED_DSDT_HASH" ]]; then
        DSDT_TMPDIR=$(mktemp -d)
        cat /sys/firmware/acpi/tables/DSDT > "$DSDT_TMPDIR/dsdt_fw.aml"
        if command -v iasl &>/dev/null && \
           iasl -d "$DSDT_TMPDIR/dsdt_fw.aml" 2>/dev/null && \
           [[ -f "$DSDT_TMPDIR/dsdt_fw.dsl" ]]; then
            if grep -q '_FST' "$DSDT_TMPDIR/dsdt_fw.dsl" && \
               ! grep -q 'SFST \[One\] = Local0' "$DSDT_TMPDIR/dsdt_fw.dsl"; then
                notify_user "Samsung Galaxy Book — Fan Speed Fix" \
                    "A firmware update has fixed fan speed reporting natively. The DSDT override has been removed. Please reboot." "info"
                "$FAN_CLEANUP"
            else
                echo "$CURRENT_DSDT_HASH" > "$DSDT_FIRMWARE_HASH"
            fi
        fi
        rm -rf "$DSDT_TMPDIR"
    fi
fi
FANCHECKEOF
chmod +x "$FAN_CHECK_SCRIPT"
sed -i "s|__DSDT_OVERRIDE_AML__|${DSDT_OVERRIDE_AML}|g" "$FAN_CHECK_SCRIPT"

cat > "/etc/systemd/system/${FAN_MONITOR_SVC}" << SVCEOF
[Unit]
Description=Samsung Galaxy Book — fan DSDT fix monitor
After=multi-user.target

[Service]
Type=oneshot
ExecStart=${FAN_CHECK_SCRIPT}
RemainAfterExit=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable "${FAN_MONITOR_SVC}" \
    && info "✓ Fan monitor service enabled" \
    || warn "systemctl enable failed for ${FAN_MONITOR_SVC}"

info "✓ Fan speed fix installed — reboot required"
