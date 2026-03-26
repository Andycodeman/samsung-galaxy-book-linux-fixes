#!/bin/bash
# =============================================================================
# Samsung Galaxy Book — Function Key Fix — Install
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

# ── Distro detection ──────────────────────────────────────────────────────────
detect_distro() {
    [[ -f /etc/os-release ]] || error "Cannot detect distro — /etc/os-release not found"
    source /etc/os-release
    local id="${ID,,}" like="${ID_LIKE:-}"; like="${like,,}"
    if [[ "$id" == "fedora" ]]; then DISTRO="fedora"
    elif [[ "$id" == "ubuntu" || "$like" == *"ubuntu"* || "$id" == "debian" || "$like" == *"debian"* ]]; then DISTRO="ubuntu"
    elif [[ "$id" == "arch" || "$like" == *"arch"* ]]; then DISTRO="arch"
    else error "Unsupported distro: $PRETTY_NAME"
    fi
}

# ── Install ───────────────────────────────────────────────────────────────────
detect_distro
KVER=$(uname -r)
KBRANCH="linux-$(uname -r | cut -d. -f1,2).y"
KERNEL_ORG="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/platform/x86"

FKEYS_PKG="samsung-galaxybook-book5pro"
FKEYS_PKG_VER="1.0"
FKEYS_SRCDIR="/usr/src/samsung-galaxybook-book5pro-1.0"
FKEYS_MODULES_CONF="/etc/modules-load.d/samsung-galaxybook.conf"
FKEYS_BLACKLIST="/etc/modprobe.d/samsung-galaxybook-blacklist.conf"
FKEYS_MONITOR_SVC="samsung-galaxybook-fkeys-monitor.service"
FKEYS_CHECK_SCRIPT="/usr/local/bin/samsung-galaxybook-fkeys-monitor.sh"
FKEYS_CLEANUP="/usr/local/bin/samsung-galaxybook-fkeys-cleanup.sh"

echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Installing: Function Key Fix                  ║"
echo "╚════════════════════════════════════════════════════════════╝"

step "F-Keys Step 1: Installing dependencies"
if [[ "$DISTRO" == "fedora" ]]; then
    dnf install -y kernel-devel-$(uname -r) kernel-headers dkms gcc make evtest \
        || error "dnf install failed"
elif [[ "$DISTRO" == "arch" ]]; then
    ARCH_KERNEL_PKG="linux-headers"
    uname -r | grep -q "\-lts"      && ARCH_KERNEL_PKG="linux-lts-headers"
    uname -r | grep -q "\-zen"      && ARCH_KERNEL_PKG="linux-zen-headers"
    uname -r | grep -q "\-hardened" && ARCH_KERNEL_PKG="linux-hardened-headers"
    pacman -S --noconfirm --needed "$ARCH_KERNEL_PKG" dkms gcc make evtest \
        || error "pacman install failed"
else
    apt-get update -q
    apt-get install -y linux-headers-$(uname -r) dkms gcc make evtest \
        || error "apt-get install failed"
fi
info "Dependencies installed"

step "F-Keys Step 2: Cleaning up any previous installation"
if dkms status 2>/dev/null | grep -q "$FKEYS_PKG"; then
    warn "Existing DKMS entry found — removing..."
    dkms remove ${FKEYS_PKG}/${FKEYS_PKG_VER} --all 2>/dev/null || true
fi
[[ -d "$FKEYS_SRCDIR" ]] && { warn "Removing old source directory..."; rm -rf "$FKEYS_SRCDIR"; }
[[ -f "$FKEYS_BLACKLIST" ]] && rm "$FKEYS_BLACKLIST"

step "F-Keys Step 3: Checking curl is available"
if ! command -v curl &>/dev/null; then
    if [[ "$DISTRO" == "fedora" ]]; then dnf install -y curl || error "Failed to install curl"
    elif [[ "$DISTRO" == "arch" ]]; then pacman -S --noconfirm --needed curl || error "Failed to install curl"
    else apt-get install -y curl || error "Failed to install curl"
    fi
fi
info "✓ curl found: $(curl --version | head -1)"

step "F-Keys Step 4: Downloading driver source (branch: $KBRANCH)"
mkdir -p "$FKEYS_SRCDIR"
curl -fSs -o "$FKEYS_SRCDIR/samsung-galaxybook.c" \
    "${KERNEL_ORG}/samsung-galaxybook.c?h=${KBRANCH}" \
    || error "Failed to download samsung-galaxybook.c — check network connection"
curl -fSs -o "$FKEYS_SRCDIR/firmware_attributes_class.h" \
    "${KERNEL_ORG}/firmware_attributes_class.h?h=${KBRANCH}" \
    || error "Failed to download firmware_attributes_class.h — check network connection"
info "Source files downloaded"

step "F-Keys Step 5: Applying hotkey patch"
python3 << 'PYEOF'
import sys

path = '/usr/src/samsung-galaxybook-book5pro-1.0/samsung-galaxybook.c'
with open(path, 'r') as f:
    src = f.read()

if '#define GB_KEY_BATTERY_NOTIFY_KEYDOWN   0x8f' not in src:
    print("ERROR: Unexpected source file — wrong kernel branch?", file=sys.stderr); sys.exit(1)
if 'hotkey_input_dev' in src:
    print("ERROR: File already patched", file=sys.stderr); sys.exit(1)

src = src.replace(
    '#define GB_KEY_BATTERY_NOTIFY_KEYDOWN   0x8f',
    '#define GB_KEY_BATTERY_NOTIFY_KEYDOWN   0x8f\n'
    '\n'
    '/* Galaxy Book 5 Pro ACPI hotkey notify codes */\n'
    '#define GB_ACPI_NOTIFY_HOTKEY_SETTINGS          0x7c\n'
    '#define GB_ACPI_NOTIFY_HOTKEY_KBD_BACKLIGHT     0x7d\n'
    '#define GB_ACPI_NOTIFY_HOTKEY_MIC_MUTE          0x6e\n'
    '#define GB_ACPI_NOTIFY_HOTKEY_WEBCAM            0x6f\n'
    '#define GB_ACPI_NOTIFY_KEY_RELEASE              0x7f\n'
    '#define GB_ACPI_NOTIFY_KEY_RELEASE2             0xff\n'
    '\n'
    '/* Galaxy Book 5 Pro F4 display switch — sent via i8042 as Super+P */\n'
    '#define GB_KEY_F4_E0                0xe0\n'
    '#define GB_KEY_F4_SUPER_PRESS       0x5b\n'
    '#define GB_KEY_F4_P_PRESS           0x19\n'
    '#define GB_KEY_F4_P_RELEASE         0x99\n'
    '#define GB_KEY_F4_SUPER_RELEASE     0xdb\n'
    '\n'
    '/* Galaxy Book 5 Pro Copilot key — sent via i8042 as Super+Shift+F23 */\n'
    '#define GB_KEY_COPILOT_SHIFT        0x2a'
)

src = src.replace(
    '\tstruct work_struct block_recording_hotkey_work;',
    '\tstruct work_struct block_recording_hotkey_work;\n'
    '\tstruct input_dev *hotkey_input_dev;\n'
    '\tint f4_state; /* state machine for F4 display switch via i8042 */'
)

old_notify = (
    '\tcase GB_ACPI_NOTIFY_HOTKEY_PERFORMANCE_MODE:\n'
    '\t\tif (galaxybook->has_performance_mode)\n'
    '\t\t\tplatform_profile_cycle();\n'
    '\t\tbreak;\n'
    '\tdefault:\n'
    '\t\tdev_warn(&galaxybook->platform->dev,\n'
    '\t\t\t "unknown ACPI notification event: 0x%x\\n", event);\n'
    '\t}'
)
new_notify = (
    '\tcase GB_ACPI_NOTIFY_HOTKEY_PERFORMANCE_MODE:\n'
    '\t\tif (galaxybook->has_performance_mode)\n'
    '\t\t\tplatform_profile_cycle();\n'
    '\t\tbreak;\n'
    '\tcase GB_ACPI_NOTIFY_HOTKEY_KBD_BACKLIGHT:\n'
    '\t\tif (galaxybook->has_kbd_backlight)\n'
    '\t\t\tschedule_work(&galaxybook->kbd_backlight_hotkey_work);\n'
    '\t\tbreak;\n'
    '\tcase GB_ACPI_NOTIFY_HOTKEY_MIC_MUTE:\n'
    '\t\tif (galaxybook->hotkey_input_dev) {\n'
    '\t\t\tinput_report_key(galaxybook->hotkey_input_dev, KEY_MICMUTE, 1);\n'
    '\t\t\tinput_sync(galaxybook->hotkey_input_dev);\n'
    '\t\t\tinput_report_key(galaxybook->hotkey_input_dev, KEY_MICMUTE, 0);\n'
    '\t\t\tinput_sync(galaxybook->hotkey_input_dev);\n'
    '\t\t}\n'
    '\t\tbreak;\n'
    '\tcase GB_ACPI_NOTIFY_HOTKEY_WEBCAM:\n'
    '\t\tif (galaxybook->hotkey_input_dev) {\n'
    '\t\t\tinput_report_key(galaxybook->hotkey_input_dev, KEY_CAMERA, 1);\n'
    '\t\t\tinput_sync(galaxybook->hotkey_input_dev);\n'
    '\t\t\tinput_report_key(galaxybook->hotkey_input_dev, KEY_CAMERA, 0);\n'
    '\t\t\tinput_sync(galaxybook->hotkey_input_dev);\n'
    '\t\t}\n'
    '\t\tbreak;\n'
    '\tcase GB_ACPI_NOTIFY_HOTKEY_SETTINGS:\n'
    '\t\tif (galaxybook->hotkey_input_dev) {\n'
    '\t\t\tinput_report_key(galaxybook->hotkey_input_dev, KEY_PROG1, 1);\n'
    '\t\t\tinput_sync(galaxybook->hotkey_input_dev);\n'
    '\t\t\tinput_report_key(galaxybook->hotkey_input_dev, KEY_PROG1, 0);\n'
    '\t\t\tinput_sync(galaxybook->hotkey_input_dev);\n'
    '\t\t}\n'
    '\t\tbreak;\n'
    '\tcase GB_ACPI_NOTIFY_KEY_RELEASE:\n'
    '\tcase GB_ACPI_NOTIFY_KEY_RELEASE2:\n'
    '\t\tbreak;\n'
    '\tdefault:\n'
    '\t\tdev_warn(&galaxybook->platform->dev,\n'
    '\t\t\t "unknown ACPI notification event: 0x%x\\n", event);\n'
    '\t}'
)
if old_notify not in src:
    print("ERROR: Could not find notify handler to patch", file=sys.stderr); sys.exit(1)
src = src.replace(old_notify, new_notify)

old_filter = '\terr = i8042_install_filter(galaxybook_i8042_filter, galaxybook);'
new_filter = (
    '\t/* Register hotkey input device for Book 5 Pro ACPI keys */\n'
    '\tgalaxybook->hotkey_input_dev = devm_input_allocate_device(&galaxybook->platform->dev);\n'
    '\tif (galaxybook->hotkey_input_dev) {\n'
    '\t\tgalaxybook->hotkey_input_dev->name = "Samsung Galaxy Book Hotkeys";\n'
    '\t\tgalaxybook->hotkey_input_dev->phys = "samsung-galaxybook/hotkeys";\n'
    '\t\tset_bit(EV_KEY,              galaxybook->hotkey_input_dev->evbit);\n'
    '\t\tset_bit(KEY_PROG1,           galaxybook->hotkey_input_dev->keybit);\n'
    '\t\tset_bit(KEY_MICMUTE,         galaxybook->hotkey_input_dev->keybit);\n'
    '\t\tset_bit(KEY_CAMERA,          galaxybook->hotkey_input_dev->keybit);\n'
    '\t\tset_bit(KEY_SWITCHVIDEOMODE, galaxybook->hotkey_input_dev->keybit);\n'
    '\t\tinput_register_device(galaxybook->hotkey_input_dev);\n'
    '\t}\n'
    '\n'
    '\terr = i8042_install_filter(galaxybook_i8042_filter, galaxybook);'
)
if old_filter not in src:
    print("ERROR: Could not find i8042_install_filter to patch", file=sys.stderr); sys.exit(1)
src = src.replace(old_filter, new_filter)

filter_6_19 = (
    '\t\t/* battery notification already sent to battery + SCAI device */\n'
    '\t\tcase GB_KEY_BATTERY_NOTIFY_KEYUP:\n'
    '\t\tcase GB_KEY_BATTERY_NOTIFY_KEYDOWN:\n'
    '\t\t\treturn true;\n'
    '\n'
    '\t\tdefault:\n'
    '\t\t\t/*\n'
    '\t\t\t * Report the previously filtered e0 before continuing\n'
    '\t\t\t * with the next non-filtered byte.\n'
    '\t\t\t */\n'
    '\t\t\tserio_interrupt(port, 0xe0, 0);\n'
    '\t\t\treturn false;\n'
    '\t\t}\n'
    '\t}\n'
    '\n'
    '\treturn false;\n'
    '}'
)
filter_6_13 = (
    '\t\tif (galaxybook->has_kbd_backlight)\n'
    '\t\t\tschedule_work(&galaxybook->kbd_backlight_hotkey_work);\n'
    '\t\treturn true;\n'
    '\t}\n'
    '\n'
    '\treturn false;\n'
    '}'
)

if filter_6_19 in src:
    print("Detected filter structure: 6.15+ (extended switch with serio_interrupt)")
    new_filter_end = (
        '\t\tcase GB_KEY_BATTERY_NOTIFY_KEYUP:\n'
        '\t\tcase GB_KEY_BATTERY_NOTIFY_KEYDOWN:\n'
        '\t\t\treturn true;\n'
        '\t\tcase GB_KEY_F4_SUPER_PRESS:\n'
        '\t\t\tgalaxybook->f4_state = 1;\n'
        '\t\t\treturn true;\n'
        '\t\tcase GB_KEY_F4_SUPER_RELEASE:\n'
        '\t\t\tif (galaxybook->f4_state == 3) {\n'
        '\t\t\t\tgalaxybook->f4_state = 0;\n'
        '\t\t\t\tif (galaxybook->hotkey_input_dev) {\n'
        '\t\t\t\t\tinput_report_key(galaxybook->hotkey_input_dev, KEY_SWITCHVIDEOMODE, 0);\n'
        '\t\t\t\t\tinput_sync(galaxybook->hotkey_input_dev);\n'
        '\t\t\t\t}\n'
        '\t\t\t\treturn true;\n'
        '\t\t\t}\n'
        '\t\t\tgalaxybook->f4_state = 0;\n'
        '\t\t\tserio_interrupt(port, 0xe0, 0);\n'
        '\t\t\tserio_interrupt(port, GB_KEY_F4_SUPER_PRESS, 0);\n'
        '\t\t\tserio_interrupt(port, 0xe0, 0);\n'
        '\t\t\treturn false;\n'
        '\t\tdefault:\n'
        '\t\t\tserio_interrupt(port, 0xe0, 0);\n'
        '\t\t\treturn false;\n'
        '\t\t}\n'
        '\t}\n'
        '\tif (galaxybook->f4_state == 1 && data == GB_KEY_COPILOT_SHIFT) {\n'
        '\t\tgalaxybook->f4_state = 0;\n'
        '\t\tserio_interrupt(port, 0xe0, 0);\n'
        '\t\tserio_interrupt(port, GB_KEY_F4_SUPER_PRESS, 0);\n'
        '\t\treturn false;\n'
        '\t}\n'
        '\tif (galaxybook->f4_state == 1 && data != GB_KEY_F4_P_PRESS) {\n'
        '\t\tgalaxybook->f4_state = 0;\n'
        '\t\tserio_interrupt(port, 0xe0, 0);\n'
        '\t\tserio_interrupt(port, GB_KEY_F4_SUPER_PRESS, 0);\n'
        '\t\treturn false;\n'
        '\t}\n'
        '\tif (galaxybook->f4_state == 1 && data == GB_KEY_F4_P_PRESS) {\n'
        '\t\tgalaxybook->f4_state = 2;\n'
        '\t\tif (galaxybook->hotkey_input_dev) {\n'
        '\t\t\tinput_report_key(galaxybook->hotkey_input_dev, KEY_SWITCHVIDEOMODE, 1);\n'
        '\t\t\tinput_sync(galaxybook->hotkey_input_dev);\n'
        '\t\t}\n'
        '\t\treturn true;\n'
        '\t}\n'
        '\tif (galaxybook->f4_state == 2 && data == GB_KEY_F4_P_RELEASE) {\n'
        '\t\tgalaxybook->f4_state = 3;\n'
        '\t\treturn true;\n'
        '\t}\n'
        '\treturn false;\n'
        '}'
    )
    src = src.replace(filter_6_19, new_filter_end)
elif filter_6_13 in src:
    print("Detected filter structure: 6.13 (simple filter)")
    new_filter_end = (
        '\t\tif (galaxybook->has_kbd_backlight)\n'
        '\t\t\tschedule_work(&galaxybook->kbd_backlight_hotkey_work);\n'
        '\t\treturn true;\n'
        '\t}\n'
        '\n'
        '\tif (extended && data == GB_KEY_F4_SUPER_PRESS) {\n'
        '\t\tgalaxybook->f4_state = 1;\n'
        '\t\treturn true;\n'
        '\t}\n'
        '\tif (extended && data == GB_KEY_F4_SUPER_RELEASE) {\n'
        '\t\tif (galaxybook->f4_state == 3) {\n'
        '\t\t\tgalaxybook->f4_state = 0;\n'
        '\t\t\tif (galaxybook->hotkey_input_dev) {\n'
        '\t\t\t\tinput_report_key(galaxybook->hotkey_input_dev, KEY_SWITCHVIDEOMODE, 0);\n'
        '\t\t\t\tinput_sync(galaxybook->hotkey_input_dev);\n'
        '\t\t\t}\n'
        '\t\t\treturn true;\n'
        '\t\t}\n'
        '\t\tgalaxybook->f4_state = 0;\n'
        '\t\treturn false;\n'
        '\t}\n'
        '\tif (galaxybook->f4_state == 1 && data == GB_KEY_COPILOT_SHIFT) {\n'
        '\t\tgalaxybook->f4_state = 0;\n'
        '\t\treturn false;\n'
        '\t}\n'
        '\tif (galaxybook->f4_state == 1 && data != GB_KEY_F4_P_PRESS) {\n'
        '\t\tgalaxybook->f4_state = 0;\n'
        '\t\treturn false;\n'
        '\t}\n'
        '\tif (galaxybook->f4_state == 1 && data == GB_KEY_F4_P_PRESS) {\n'
        '\t\tgalaxybook->f4_state = 2;\n'
        '\t\tif (galaxybook->hotkey_input_dev) {\n'
        '\t\t\tinput_report_key(galaxybook->hotkey_input_dev, KEY_SWITCHVIDEOMODE, 1);\n'
        '\t\t\tinput_sync(galaxybook->hotkey_input_dev);\n'
        '\t\t}\n'
        '\t\treturn true;\n'
        '\t}\n'
        '\tif (galaxybook->f4_state == 2 && data == GB_KEY_F4_P_RELEASE) {\n'
        '\t\tgalaxybook->f4_state = 3;\n'
        '\t\treturn true;\n'
        '\t}\n'
        '\treturn false;\n'
        '}'
    )
    src = src.replace(filter_6_13, new_filter_end)
else:
    print("ERROR: Could not identify i8042 filter structure — unsupported kernel version?", file=sys.stderr)
    sys.exit(1)

old_guard = (
    '\tif (!galaxybook->has_kbd_backlight && !galaxybook->has_block_recording)\n'
    '\t\treturn 0;'
)
if old_guard in src:
    src = src.replace(old_guard,
        '\t/* Always install — register hotkey_input_dev for Book 5 Pro ACPI keys */')

with open(path, 'w') as f:
    f.write(src)

checks = {
    'GB_ACPI_NOTIFY_HOTKEY_SETTINGS': '0x7c F1', 'GB_ACPI_NOTIFY_HOTKEY_KBD_BACKLIGHT': '0x7d F9',
    'GB_ACPI_NOTIFY_HOTKEY_MIC_MUTE': '0x6e F10', 'GB_ACPI_NOTIFY_HOTKEY_WEBCAM': '0x6f F11',
    'KEY_PROG1': 'F1 settings', 'KEY_MICMUTE': 'F10 mic mute', 'KEY_CAMERA': 'F11 webcam',
    'hotkey_input_dev': 'input device', 'KEY_RELEASE2': 'release ignore',
    'Samsung Galaxy Book Hotkeys': 'input dev name', 'GB_KEY_F4_E0': 'F4 define',
    'KEY_SWITCHVIDEOMODE': 'F4 display switch', 'f4_state': 'F4 state machine',
    'GB_KEY_COPILOT_SHIFT': 'Copilot key',
}
failed = [f"{t} ({d})" for t, d in checks.items() if t not in src]
if failed:
    print("ERROR: Patch verification failed — missing:", file=sys.stderr)
    for item in failed: print(f"  ✗ {item}", file=sys.stderr)
    sys.exit(1)
print(f"All {len(checks)} patch checks passed")
PYEOF
info "Patch applied and verified"

step "F-Keys Step 6: Creating Makefile and dkms.conf"
cat > "$FKEYS_SRCDIR/Makefile" << 'EOF'
obj-m := samsung-galaxybook.o
KVER ?= $(shell uname -r)
KDIR := /lib/modules/$(KVER)/build
EXTRA_CFLAGS += -I$(src)
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF

cat > "$FKEYS_SRCDIR/dkms.conf" << 'EOF'
PACKAGE_NAME="samsung-galaxybook-book5pro"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="samsung-galaxybook"
DEST_MODULE_LOCATION[0]="/extra"
AUTOINSTALL="yes"
EOF
info "Makefile and dkms.conf created"

step "F-Keys Step 7: Registering with DKMS"
dkms add ${FKEYS_PKG}/${FKEYS_PKG_VER} || error "dkms add failed"

step "F-Keys Step 8: Building module"
dkms build ${FKEYS_PKG}/${FKEYS_PKG_VER} \
    || error "dkms build failed — check /var/lib/dkms/${FKEYS_PKG}/${FKEYS_PKG_VER}/build/make.log"

step "F-Keys Step 9: Installing module"
dkms install ${FKEYS_PKG}/${FKEYS_PKG_VER} || error "dkms install failed"
info "Module installed to /lib/modules/$KVER/extra/"

step "F-Keys Step 10: Configuring module to load on boot"
echo "samsung_galaxybook" > "$FKEYS_MODULES_CONF"

step "F-Keys Step 11: Loading patched module"
modprobe -r samsung_galaxybook 2>/dev/null || true
modprobe samsung_galaxybook || error "modprobe failed — check dmesg"

step "F-Keys Step 12: Storing kernel version for upstream merge detection"
mkdir -p /var/lib/samsung-galaxybook
echo "$KVER" > /var/lib/samsung-galaxybook/fkeys-kernel.ver
chmod 644 /var/lib/samsung-galaxybook/fkeys-kernel.ver
info "Kernel version stored: $KVER"

step "F-Keys Step 13: Installing function key monitor service"
cat > "$FKEYS_CLEANUP" << FKEYSCLEANEOF
#!/bin/bash
# Samsung Galaxy Book — remove DKMS function key fix (runs as root)
FKEYS_PKG="samsung-galaxybook-book5pro"; FKEYS_PKG_VER="1.0"
FKEYS_SRCDIR="/usr/src/samsung-galaxybook-book5pro-1.0"
modprobe -r samsung_galaxybook 2>/dev/null || true
dkms remove \${FKEYS_PKG}/\${FKEYS_PKG_VER} --all 2>/dev/null || true
rm -rf "\$FKEYS_SRCDIR"
rm -f /etc/modules-load.d/samsung-galaxybook.conf
modprobe samsung_galaxybook 2>/dev/null || true
rm -f /var/lib/samsung-galaxybook/fkeys-kernel.ver
systemctl disable ${FKEYS_MONITOR_SVC} 2>/dev/null || true
rm -f /etc/systemd/system/${FKEYS_MONITOR_SVC}
systemctl daemon-reload 2>/dev/null || true
rm -f ${FKEYS_CHECK_SCRIPT}
rm -f ${FKEYS_CLEANUP}
FKEYSCLEANEOF
chmod 750 "$FKEYS_CLEANUP"

cat > "$FKEYS_CHECK_SCRIPT" << 'FKEYSCHECKEOF'
#!/bin/bash
# Samsung Galaxy Book — function key fix monitor (system service, runs as root)
FKEYS_CLEANUP="/usr/local/bin/samsung-galaxybook-fkeys-cleanup.sh"
FKEYS_VER_FILE="/var/lib/samsung-galaxybook/fkeys-kernel.ver"
FKEYS_PKG="samsung-galaxybook-book5pro"; FKEYS_PKG_VER="1.0"
KERNEL_ORG="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/platform/x86"

notify_user() {
    local title="$1" msg="$2"
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

if [[ -f "$FKEYS_VER_FILE" ]] && dkms status 2>/dev/null | grep -q "${FKEYS_PKG}/${FKEYS_PKG_VER}"; then
    STORED_KVER=$(cat "$FKEYS_VER_FILE")
    CURRENT_KVER=$(uname -r)
    if [[ "$CURRENT_KVER" != "$STORED_KVER" ]]; then
        KBRANCH="linux-$(echo "$CURRENT_KVER" | cut -d. -f1,2).y"
        TMPFILE=$(mktemp /tmp/samsung-galaxybook-XXXXXX.c)
        if curl -fsSL --max-time 15 "${KERNEL_ORG}/samsung-galaxybook.c?h=${KBRANCH}" -o "$TMPFILE" 2>/dev/null; then
            NATIVE=true
            for PATCH_MARKER in "GB_ACPI_NOTIFY_HOTKEY_SETTINGS" "hotkey_input_dev" "KEY_MICMUTE" "f4_state"; do
                grep -q "$PATCH_MARKER" "$TMPFILE" || { NATIVE=false; break; }
            done
            if $NATIVE; then
                notify_user "Samsung Galaxy Book — Function Key Fix" \
                    "The upstream kernel ($CURRENT_KVER) now includes the function key patches natively. The DKMS module has been removed."
                "$FKEYS_CLEANUP"
            else
                echo "$CURRENT_KVER" > "$FKEYS_VER_FILE" 2>/dev/null || true
            fi
        fi
        rm -f "$TMPFILE"
    fi
fi
FKEYSCHECKEOF
chmod +x "$FKEYS_CHECK_SCRIPT"

cat > "/etc/systemd/system/${FKEYS_MONITOR_SVC}" << SVCEOF
[Unit]
Description=Samsung Galaxy Book — function key fix monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${FKEYS_CHECK_SCRIPT}
RemainAfterExit=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable "${FKEYS_MONITOR_SVC}" \
    && info "✓ Function key monitor service enabled" \
    || warn "systemctl enable failed for ${FKEYS_MONITOR_SVC}"

step "F-Keys Step 14: Installing Copilot key XKB workaround"
COPILOT_USER=$(loginctl list-sessions --no-legend | awk '$4 == "seat0" {print $3}' | head -1)
COPILOT_HOME=$(getent passwd "$COPILOT_USER" | cut -d: -f6)
COPILOT_DBUS="unix:path=/run/user/$(id -u "$COPILOT_USER")/bus"
COPILOT_XKB_DIR="$COPILOT_HOME/.config/xkb/symbols"
COPILOT_XKB_FILE="$COPILOT_XKB_DIR/inet"

if [[ -z "$COPILOT_USER" || -z "$COPILOT_HOME" ]]; then
    warn "Could not detect logged-in user — skipping Copilot key XKB workaround"
else
    if [[ ! -f "$COPILOT_XKB_FILE" ]]; then
        sudo -u "$COPILOT_USER" mkdir -p "$COPILOT_XKB_DIR"
        sudo -u "$COPILOT_USER" tee "$COPILOT_XKB_FILE" > /dev/null << 'XKBEOF'
partial alphanumeric_keys
xkb_symbols "evdev" {
    include "%S/inet(evdev)"
    key <FK23>   {      [ XF86TouchpadOff, F23 ], type[Group1] = "PC_SHIFT_SUPER_LEVEL2" };
};
XKBEOF
        info "✓ Copilot key XKB inet file installed for $COPILOT_USER"
    else
        info "Copilot key XKB inet file already present — skipping"
    fi

    if ps -u "$COPILOT_USER" -o comm= 2>/dev/null | grep -qi "plasmashell"; then
        COPILOT_DE="kde"
    elif ps -u "$COPILOT_USER" -o comm= 2>/dev/null | grep -qi "gnome-shell"; then
        COPILOT_DE="gnome"
    elif ps -u "$COPILOT_USER" -o comm= 2>/dev/null | grep -qi "cinnamon"; then
        COPILOT_DE="cinnamon"
    else
        COPILOT_DE="unknown"
    fi

    if echo "$COPILOT_DE" | grep -qi "kde\|plasma"; then
        EXISTING_OPTS=$(sudo -u "$COPILOT_USER" \
            XDG_RUNTIME_DIR="/run/user/$(id -u "$COPILOT_USER")" \
            DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
            kreadconfig6 --file kxkbrc --group Layout --key Options 2>/dev/null || true)
        if ! echo "$EXISTING_OPTS" | grep -q "fkeys:basic_13-24"; then
            NEW_OPTS="fkeys:basic_13-24"
            [[ -n "$EXISTING_OPTS" ]] && NEW_OPTS="${EXISTING_OPTS},fkeys:basic_13-24"
            sudo -u "$COPILOT_USER" \
                XDG_RUNTIME_DIR="/run/user/$(id -u "$COPILOT_USER")" \
                DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
                kwriteconfig6 --file kxkbrc --group Layout --key Options "$NEW_OPTS"
            sudo -u "$COPILOT_USER" \
                XDG_RUNTIME_DIR="/run/user/$(id -u "$COPILOT_USER")" \
                DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
                kwriteconfig6 --file kxkbrc --group Layout --key ResetOldOptions "true"
            sudo -u "$COPILOT_USER" \
                DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
                dbus-send --type=signal /Layouts org.kde.keyboard.reloadConfig 2>/dev/null || true
            KWIN_QDBUS=""
            command -v qdbus-qt6 &>/dev/null && KWIN_QDBUS="qdbus-qt6"
            [[ -z "$KWIN_QDBUS" ]] && command -v qdbus6 &>/dev/null && KWIN_QDBUS="qdbus6"
            if [[ -n "$KWIN_QDBUS" ]]; then
                sudo -u "$COPILOT_USER" \
                    DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
                    "$KWIN_QDBUS" org.kde.KWin /KWin reconfigure 2>/dev/null || true
            fi
            info "✓ KDE fkeys:basic_13-24 xkb option enabled"
        else
            info "KDE fkeys:basic_13-24 already set"
        fi
    elif echo "$COPILOT_DE" | grep -qi "gnome\|unity"; then
        EXISTING_OPTS=$(sudo -u "$COPILOT_USER" DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
            gsettings get org.gnome.desktop.input-sources xkb-options 2>/dev/null || echo "[]")
        if ! echo "$EXISTING_OPTS" | grep -q "fkeys:basic_13-24"; then
            NEW_OPTS=$(echo "$EXISTING_OPTS" | python3 -c "
import sys,json; raw=sys.stdin.read().strip()
opts=json.loads(raw.replace(\"'\", '\"'))
if 'fkeys:basic_13-24' not in opts: opts.append('fkeys:basic_13-24')
print(json.dumps(opts).replace('\"', \"'\"))
" 2>/dev/null || echo "['fkeys:basic_13-24']")
            sudo -u "$COPILOT_USER" DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
                gsettings set org.gnome.desktop.input-sources xkb-options "$NEW_OPTS"
            info "✓ GNOME fkeys:basic_13-24 xkb option enabled"
        fi
    elif echo "$COPILOT_DE" | grep -qi "cinnamon"; then
        EXISTING_OPTS=$(sudo -u "$COPILOT_USER" DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
            gsettings get org.cinnamon.desktop.input-sources xkb-options 2>/dev/null || echo "[]")
        if ! echo "$EXISTING_OPTS" | grep -q "fkeys:basic_13-24"; then
            NEW_OPTS=$(echo "$EXISTING_OPTS" | python3 -c "
import sys,json; raw=sys.stdin.read().strip()
opts=json.loads(raw.replace(\"'\", '\"'))
if 'fkeys:basic_13-24' not in opts: opts.append('fkeys:basic_13-24')
print(json.dumps(opts).replace('\"', \"'\"))
" 2>/dev/null || echo "['fkeys:basic_13-24']")
            sudo -u "$COPILOT_USER" DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
                gsettings set org.cinnamon.desktop.input-sources xkb-options "$NEW_OPTS"
            info "✓ Cinnamon fkeys:basic_13-24 xkb option enabled"
        fi
    else
        warn "Desktop environment '$COPILOT_DE' — using setxkbmap autostart for fkeys:basic_13-24"
        AUTOSTART_DIR="$COPILOT_HOME/.config/autostart"
        AUTOSTART_FILE="$AUTOSTART_DIR/samsung-galaxybook-fkeys.desktop"
        if [[ ! -f "$AUTOSTART_FILE" ]]; then
            sudo -u "$COPILOT_USER" mkdir -p "$AUTOSTART_DIR"
            sudo -u "$COPILOT_USER" tee "$AUTOSTART_FILE" > /dev/null << 'AUTOSTARTEOF'
[Desktop Entry]
Type=Application
Name=Samsung Galaxy Book — Copilot Key Fix
Exec=setxkbmap -option fkeys:basic_13-24
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
AUTOSTARTEOF
            info "✓ setxkbmap autostart entry installed for $COPILOT_USER"
        fi
    fi
fi

info "✓ Function key fix installed — reboot required"
