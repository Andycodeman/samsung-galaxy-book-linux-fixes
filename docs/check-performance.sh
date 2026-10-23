#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# check-performance.sh — Non-intrusive diagnostic tool for platform profiles,
# CPU power limits (DTT/RAPL), EPP, and GPU Dynamic Boost on Samsung Galaxy Book laptops.
#
# Reads sysfs and systemctl. Does not require root.

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

echo -e "${BOLD}================================================================${RESET}"
echo -e "${BOLD}  Samsung Galaxy Book — Performance & Power Limits Diagnostic  ${RESET}"
echo -e "${BOLD}================================================================${RESET}"

# 1. Platform Profile
echo -e "\n${CYAN}[1/5] Platform Profile (ACPI \\_SB.SCAI.PRF3)${RESET}"
if [ -r /sys/firmware/acpi/platform_profile ]; then
    CURRENT_PROFILE=$(cat /sys/firmware/acpi/platform_profile)
    CHOICES=$(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null || echo "unknown")
    echo -e "  Current profile : ${BOLD}${GREEN}${CURRENT_PROFILE}${RESET}"
    echo -e "  Available       : ${CHOICES}"
else
    echo -e "  ${YELLOW}platform_profile not exposed by kernel (samsung-galaxybook loaded?)${RESET}"
fi

# 2. DTT ODVP state
echo -e "\n${CYAN}[2/5] Intel Dynamic Tuning Technology (DTT / SCAI)${RESET}"
ODVP_FOUND=false
for dev in /sys/bus/platform/devices/INTC10*; do
    if [ -r "${dev}/odvp0" ]; then
        ODVP_VAL=$(cat "${dev}/odvp0")
        MODE_NAME="unknown"
        case "$ODVP_VAL" in
            21|0x15) MODE_NAME="Performance (0x15)" ;;
            2|0x02)  MODE_NAME="Balanced / Optimized (0x02)" ;;
            10|0x0a) MODE_NAME="Quiet / Low Noise (0x0A)" ;;
            0|0x00)  MODE_NAME="Default / Auto (0x00)" ;;
        esac
        echo -e "  Device ${dev##*/} odvp0 : ${BOLD}${ODVP_VAL}${RESET} (${MODE_NAME})"
        ODVP_FOUND=true
    fi
done
if [ "$ODVP_FOUND" = false ]; then
    echo -e "  ${YELLOW}No INTC10* DTT device with odvp0 found${RESET}"
fi

# 3. CPU Power Limits (RAPL MMIO vs MSR)
echo -e "\n${CYAN}[3/5] CPU Power Limits (RAPL)${RESET}"
MMIO_DIR="/sys/devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0"
MSR_DIR="/sys/class/powercap/intel-rapl:0"

if [ -d "$MMIO_DIR" ]; then
    echo -e "  ${BOLD}MMIO RAPL (applied by thermald from DTT GDDV tables):${RESET}"
    for i in 0 1 2; do
        if [ -r "${MMIO_DIR}/constraint_${i}_name" ] && [ -r "${MMIO_DIR}/constraint_${i}_power_limit_uw" ]; then
            CNAME=$(cat "${MMIO_DIR}/constraint_${i}_name")
            CLIM_UW=$(cat "${MMIO_DIR}/constraint_${i}_power_limit_uw")
            CLIM_W=$((CLIM_UW / 1000000))
            echo -e "    - constraint_${i} (${CNAME}) : ${BOLD}${CLIM_W} W${RESET} (${CLIM_UW} µW)"
        fi
    done
else
    echo -e "  ${YELLOW}intel-rapl-mmio not active${RESET}"
fi

if [ -d "$MSR_DIR" ]; then
    if [ -r "${MSR_DIR}/constraint_0_power_limit_uw" ]; then
        MSR_PL1=$(( $(cat "${MSR_DIR}/constraint_0_power_limit_uw") / 1000000 ))
        MSR_PL2=$(( $(cat "${MSR_DIR}/constraint_1_power_limit_uw" 2>/dev/null || echo 0) / 1000000 ))
        echo -e "  MSR RAPL (base ceiling) : PL1=${MSR_PL1} W, PL2=${MSR_PL2} W (CPU enforces min(MSR, MMIO))"
    fi
fi

# 4. Energy Performance Preference (EPP) & thermald
echo -e "\n${CYAN}[4/5] Governor EPP & Thermal Daemon${RESET}"
if [ -r /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]; then
    EPP_VAL=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)
    echo -e "  CPU0 EPP        : ${BOLD}${GREEN}${EPP_VAL}${RESET}"
fi

if command -v systemctl >/dev/null 2>&1; then
    THERMALD_ACTIVE=$(systemctl is-active thermald 2>/dev/null || echo "inactive")
    THERMALD_ENABLED=$(systemctl is-enabled thermald 2>/dev/null || echo "disabled")
    echo -e "  thermald.service: ${BOLD}${THERMALD_ACTIVE}${RESET} (preset/enabled: ${THERMALD_ENABLED})"
fi

# 5. NVIDIA Discrete GPU & Dynamic Boost (nvidia-powerd)
echo -e "\n${CYAN}[5/5] Discrete GPU & Dynamic Boost${RESET}"
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo "NVIDIA GPU")
    POWER_INFO=$(nvidia-smi --query-gpu=power.limit,enforced.power.limit,power.max_limit --format=csv,noheader 2>/dev/null | head -n1 || echo "")
    
    echo -e "  GPU Model       : ${BOLD}${GPU_NAME}${RESET}"
    if [ -n "$POWER_INFO" ]; then
        IFS=',' read -r PLIMIT ENFORCED MAXLIM <<< "$POWER_INFO"
        echo -e "  Power Limits    : Enforced=${BOLD}${ENFORCED## }${RESET}, Default=${PLIMIT## }, Max=${MAXLIM## }"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        NPD_ACTIVE=$(systemctl is-active nvidia-powerd 2>/dev/null || echo "inactive")
        NPD_ENABLED=$(systemctl is-enabled nvidia-powerd 2>/dev/null || echo "disabled")
        echo -e "  nvidia-powerd   : ${BOLD}${NPD_ACTIVE}${RESET} (enabled: ${NPD_ENABLED})"

        if [ "$NPD_ACTIVE" != "active" ]; then
            echo -e "\n  ${YELLOW}${BOLD}⚠ NOTE: nvidia-powerd.service is inactive.${RESET}"
            echo -e "    Without nvidia-powerd, the GPU cannot receive ACPI Dynamic Boost"
            echo -e "    notifications and stays capped at the base TGP (typically 55 W)."
            echo -e "    To enable Dynamic Boost up to 80 W on Book4 Ultra:"
            echo -e "      ${BOLD}sudo systemctl enable --now nvidia-powerd${RESET}"
        fi
    fi
else
    echo -e "  No discrete NVIDIA GPU / nvidia-smi detected (Intel integrated graphics only)."
fi

echo -e "\n${BOLD}================================================================${RESET}"
