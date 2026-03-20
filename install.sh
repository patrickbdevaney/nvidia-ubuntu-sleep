#!/usr/bin/env bash
# =============================================================================
# nvidia-sleep-fix: Bulletproof NVIDIA GPU suspend/resume for Ubuntu/Linux
# https://github.com/yourusername/nvidia-sleep-fix
#
# Tested on:
#   - Ubuntu 24.04 LTS / 24.10
#   - Kernel 6.11.x, 6.8.x
#   - NVIDIA driver 570.x, 560.x, 550.x
#   - Gigabyte B550, X570, Z790 motherboards (AMD & Intel)
#   - RTX 3090, 3080, 4090, 4080 (any modern NVIDIA GPU)
#
# Symptoms this fixes:
#   - GPU fans spinning full blast during suspend
#   - Blue LED / RGB staying on during suspend
#   - System appearing suspended but GPU fully powered
#   - Wake-on-LAN unresponsive because GPU holds PCIe awake
#   - Suspend working intermittently then breaking after driver/kernel update
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}\n"; }

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "Run as root: sudo bash install.sh"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

header "NVIDIA Sleep Fix — System Detection"

# ── Detect NVIDIA driver ──────────────────────────────────────────────────────
if ! command -v nvidia-smi &>/dev/null; then
    error "nvidia-smi not found. Is the NVIDIA driver installed?"
    exit 1
fi

DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
DRIVER_MAJOR=$(echo "$DRIVER_VERSION" | cut -d. -f1)
info "NVIDIA driver: $DRIVER_VERSION"

# Detect driver package name (e.g. nvidia-driver-570)
DRIVER_PKG=$(dpkg -l 'nvidia-driver-*' 2>/dev/null | awk '/^ii/{print $2}' | head -1)
info "NVIDIA package: ${DRIVER_PKG:-unknown}"

# ── Detect kernel ─────────────────────────────────────────────────────────────
KERNEL=$(uname -r)
info "Kernel: $KERNEL"

# ── Detect GPU ───────────────────────────────────────────────────────────────
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
info "GPU: $GPU_NAME"

# ── Detect motherboard ────────────────────────────────────────────────────────
BOARD_VENDOR=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || echo "unknown")
BOARD_NAME=$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo "unknown")
info "Motherboard: $BOARD_VENDOR $BOARD_NAME"

# ── Detect problematic ACPI wakeup sources ────────────────────────────────────
WAKEUP_FILE="/proc/acpi/wakeup"
WAKEUP_SOURCES=()
for source in GPP0 GPP1 GPP2 PTXH XHC0 XHC1 XHC2 XHCI; do
    if grep -q "^${source}.*enabled" "$WAKEUP_FILE" 2>/dev/null; then
        WAKEUP_SOURCES+=("$source")
    fi
done

if [[ ${#WAKEUP_SOURCES[@]} -gt 0 ]]; then
    warn "Problematic wakeup sources detected: ${WAKEUP_SOURCES[*]}"
else
    info "No known problematic wakeup sources detected"
fi

# ── Detect existing conflicting sleep hooks ───────────────────────────────────
CONFLICTS=()
for f in /etc/systemd/system-sleep/nvidia-suspend.sh \
          /etc/systemd/system-sleep/nvidia-fix.sh \
          /etc/systemd/system-sleep/gpu-sleep.sh; do
    [[ -f "$f" ]] && CONFLICTS+=("$f")
done

if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
    warn "Conflicting custom sleep hooks found: ${CONFLICTS[*]}"
fi

# ── Detect NIC for Wake-on-LAN ────────────────────────────────────────────────
DEFAULT_NIC=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
info "Default NIC: ${DEFAULT_NIC:-not detected}"

echo ""
echo -e "${BOLD}Detected configuration summary:${RESET}"
echo "  Driver:      $DRIVER_VERSION (pkg: ${DRIVER_PKG:-unknown})"
echo "  Kernel:      $KERNEL"
echo "  GPU:         $GPU_NAME"
echo "  Board:       $BOARD_VENDOR $BOARD_NAME"
echo "  Wakeup srcs: ${WAKEUP_SOURCES[*]:-none problematic}"
echo "  NIC (WoL):   ${DEFAULT_NIC:-unknown}"
echo ""
read -rp "Proceed with installation? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

header "Step 1: NVIDIA Module Parameters"

# Write modprobe config — survives driver updates
MODPROBE_CONF="/etc/modprobe.d/nvidia-power-management.conf"
cat > "$MODPROBE_CONF" << 'EOF'
# nvidia-sleep-fix: Power management parameters for reliable suspend/resume
# https://github.com/yourusername/nvidia-sleep-fix
#
# NVreg_PreserveVideoMemoryAllocations=1
#   Tells the driver to save GPU video memory to disk/RAM before suspend.
#   Without this, the GPU cannot properly power down — fans keep spinning.
#
# NVreg_TemporaryFilePath=/var/tmp
#   Where to store saved GPU memory during suspend. /var/tmp persists across
#   resume unlike /tmp which may be cleared.
#
# fbdev=1
#   Enables framebuffer device support for the nvidia-drm module,
#   required for proper KMS/suspend handoff on modern kernels.

options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var/tmp
options nvidia-drm modeset=1
options nvidia-drm fbdev=1
EOF

success "Written: $MODPROBE_CONF"

header "Step 2: Verify NVIDIA Systemd Services"

REQUIRED_SERVICES=(nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service)
for svc in "${REQUIRED_SERVICES[@]}"; do
    if systemctl list-unit-files "$svc" &>/dev/null; then
        systemctl enable "$svc" &>/dev/null && success "Enabled: $svc"
    else
        warn "Service not found: $svc (driver may not support it)"
    fi
done

header "Step 3: Wire NVIDIA Into Suspend Dependency Tree"

# Drop-ins force systemd to run nvidia-suspend BEFORE systemd-suspend,
# and nvidia-resume AFTER systemd-resume. This is the critical wiring
# that is often missing or broken after driver updates.

mkdir -p /etc/systemd/system/systemd-suspend.service.d
cat > /etc/systemd/system/systemd-suspend.service.d/nvidia.conf << 'EOF'
# nvidia-sleep-fix: Ensure nvidia-suspend runs before system suspend
[Unit]
Wants=nvidia-suspend.service
After=nvidia-suspend.service
EOF
success "Written: systemd-suspend drop-in"

mkdir -p /etc/systemd/system/systemd-resume.service.d
cat > /etc/systemd/system/systemd-resume.service.d/nvidia.conf << 'EOF'
# nvidia-sleep-fix: Ensure nvidia-resume runs after system resume
[Unit]
Wants=nvidia-resume.service
Before=nvidia-resume.service
EOF
success "Written: systemd-resume drop-in"

mkdir -p /etc/systemd/system/systemd-hibernate.service.d
cat > /etc/systemd/system/systemd-hibernate.service.d/nvidia.conf << 'EOF'
[Unit]
Wants=nvidia-hibernate.service
After=nvidia-hibernate.service
EOF
success "Written: systemd-hibernate drop-in"

header "Step 4: Remove Conflicting Custom Sleep Hooks"

for f in "${CONFLICTS[@]}"; do
    mv "$f" "${f}.bak.$(date +%Y%m%d)"
    warn "Backed up conflicting hook: $f → ${f}.bak"
done

# Verify the canonical nvidia sleep hook exists
if [[ -f /usr/lib/systemd/system-sleep/nvidia ]]; then
    success "Canonical NVIDIA sleep hook present: /usr/lib/systemd/system-sleep/nvidia"
else
    warn "/usr/lib/systemd/system-sleep/nvidia missing — your driver package may be incomplete"
    warn "Try: sudo apt install --reinstall \$DRIVER_PKG"
fi

header "Step 5: Disable Problematic ACPI Wakeup Sources"

# Build the wakeup disable service dynamically based on what was detected
WAKEUP_EXEC_LINES=""
if [[ ${#WAKEUP_SOURCES[@]} -gt 0 ]]; then
    for src in "${WAKEUP_SOURCES[@]}"; do
        WAKEUP_EXEC_LINES+="ExecStart=/bin/sh -c 'echo ${src} > /proc/acpi/wakeup'\n"
    done
else
    # Safe defaults that cover Gigabyte B550/X570 and most AMD platforms
    # On Intel/other boards these are harmless no-ops if not present
    for src in GPP0 PTXH XHC0; do
        WAKEUP_EXEC_LINES+="ExecStart=/bin/sh -c 'echo ${src} > /proc/acpi/wakeup'\n"
    done
    warn "No wakeup sources detected at runtime — using safe defaults (GPP0, PTXH, XHC0)"
fi

cat > /etc/systemd/system/nvidia-wakeup-disable.service << EOF
# nvidia-sleep-fix: Disable PCIe/USB wakeup sources that prevent GPU power-down
# Sources disabled: ${WAKEUP_SOURCES[*]:-GPP0 PTXH XHC0 (defaults)}
[Unit]
Description=Disable PCIe and USB wakeup sources for reliable NVIDIA suspend
After=network.target

[Service]
Type=oneshot
$(echo -e "$WAKEUP_EXEC_LINES")RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nvidia-wakeup-disable.service
success "Wakeup disable service installed and running"

# Verify
echo ""
info "Current wakeup source states:"
cat /proc/acpi/wakeup | grep -iE "GPP|PTXH|XHC" || true

header "Step 6: Wake-on-LAN (Optional)"

if [[ -n "$DEFAULT_NIC" ]]; then
    if command -v ethtool &>/dev/null; then
        cat > /etc/systemd/system/wol-enable.service << EOF
[Unit]
Description=Enable Wake-on-LAN on $DEFAULT_NIC
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -s $DEFAULT_NIC wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

        # Sleep hook to re-arm WoL after resume (some NICs reset it)
        cat > /usr/lib/systemd/system-sleep/wol-rearm.sh << EOF
#!/bin/bash
# nvidia-sleep-fix: Re-arm Wake-on-LAN after resume
case "\$1/\$2" in
  post/*)
    /sbin/ethtool -s $DEFAULT_NIC wol g
    ;;
esac
EOF
        chmod +x /usr/lib/systemd/system-sleep/wol-rearm.sh
        systemctl daemon-reload
        systemctl enable --now wol-enable.service
        success "Wake-on-LAN enabled for $DEFAULT_NIC"
    else
        warn "ethtool not found — skipping WoL setup. Install with: apt install ethtool"
    fi
else
    warn "Could not detect default NIC — skipping WoL setup"
    warn "Run manually: sudo ethtool -s <your-nic> wol g"
fi

header "Step 7: APT Hook — Auto-rebuild initramfs After NVIDIA Updates"

cat > /etc/apt/apt.conf.d/99-nvidia-sleep-fix << 'EOF'
# nvidia-sleep-fix: Rebuild initramfs whenever an NVIDIA package is updated
# This ensures NVreg_PreserveVideoMemoryAllocations and other modprobe options
# are always baked into the initramfs after driver upgrades.
DPkg::Post-Invoke {
    "if dpkg -l 'nvidia-*' 2>/dev/null | grep -q '^ii'; then update-initramfs -u -k all; fi";
};
EOF
success "Written: /etc/apt/apt.conf.d/99-nvidia-sleep-fix"

header "Step 8: Driver Version Hold (Recommended)"

if [[ -n "$DRIVER_PKG" ]]; then
    echo ""
    echo -e "${YELLOW}Hold the current NVIDIA driver to prevent silent major version upgrades?${RESET}"
    echo "  Current: $DRIVER_PKG ($DRIVER_VERSION)"
    echo "  This prevents apt from jumping to a new major driver during routine upgrades."
    echo "  You can unhold later with: sudo apt-mark unhold $DRIVER_PKG"
    echo ""
    read -rp "Hold $DRIVER_PKG? [y/N] " hold_confirm
    if [[ "$hold_confirm" =~ ^[Yy]$ ]]; then
        apt-mark hold "$DRIVER_PKG"
        success "Held: $DRIVER_PKG"
    else
        info "Skipped driver hold"
    fi
fi

header "Step 9: Install check-suspend Health Check"

CHECK_SCRIPT="/usr/local/bin/check-suspend"
cat > "$CHECK_SCRIPT" << 'CHECKEOF'
#!/usr/bin/env bash
# nvidia-sleep-fix: Suspend health check
# Run after any apt upgrade to verify the suspend chain is intact.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}[OK]${RESET}   $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; FAILURES=$((FAILURES+1)); }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }

FAILURES=0

echo -e "\n${BOLD}${CYAN}NVIDIA Suspend Health Check${RESET}\n"

# 1. PreserveVideoMemoryAllocations
VAL=$(cat /proc/driver/nvidia/params 2>/dev/null | grep PreserveVideoMemoryAllocations | awk '{print $2}')
if [[ "$VAL" == "1" ]]; then
    ok "NVreg_PreserveVideoMemoryAllocations=1"
else
    fail "NVreg_PreserveVideoMemoryAllocations is ${VAL:-not set} (should be 1)"
    echo "     Fix: check /etc/modprobe.d/nvidia-power-management.conf and run sudo update-initramfs -u -k all"
fi

# 2. nvidia-suspend.service in dependency tree
if systemctl list-dependencies systemd-suspend.service 2>/dev/null | grep -q nvidia-suspend; then
    ok "nvidia-suspend.service is in suspend dependency tree"
else
    fail "nvidia-suspend.service is NOT in suspend dependency tree"
    echo "     Fix: check /etc/systemd/system/systemd-suspend.service.d/nvidia.conf"
fi

# 3. nvidia-resume.service enabled
if systemctl is-enabled nvidia-resume.service &>/dev/null; then
    ok "nvidia-resume.service is enabled"
else
    fail "nvidia-resume.service is not enabled"
    echo "     Fix: sudo systemctl enable nvidia-resume.service"
fi

# 4. Wakeup sources
WAKEUP_BAD=()
for src in GPP0 GPP1 PTXH XHC0 XHC1; do
    if grep -q "^${src}.*\*enabled" /proc/acpi/wakeup 2>/dev/null; then
        WAKEUP_BAD+=("$src")
    fi
done
if [[ ${#WAKEUP_BAD[@]} -eq 0 ]]; then
    ok "No problematic ACPI wakeup sources enabled"
else
    fail "Wakeup sources still enabled: ${WAKEUP_BAD[*]}"
    echo "     Fix: sudo systemctl restart nvidia-wakeup-disable.service"
fi

# 5. Conflicting sleep hooks
CONFLICTS=()
for f in /etc/systemd/system-sleep/nvidia-suspend.sh \
          /etc/systemd/system-sleep/nvidia-fix.sh; do
    [[ -f "$f" ]] && CONFLICTS+=("$f")
done
if [[ ${#CONFLICTS[@]} -eq 0 ]]; then
    ok "No conflicting custom sleep hooks found"
else
    fail "Conflicting sleep hooks present: ${CONFLICTS[*]}"
    echo "     Fix: mv the above files to .bak"
fi

# 6. Canonical nvidia sleep hook
if [[ -x /usr/lib/systemd/system-sleep/nvidia ]]; then
    ok "Canonical NVIDIA sleep hook present and executable"
else
    fail "/usr/lib/systemd/system-sleep/nvidia missing or not executable"
    echo "     Fix: sudo apt install --reinstall \$(dpkg -l 'nvidia-driver-*' | awk '/^ii/{print \$2}' | head-1)"
fi

# 7. TemporaryFilePath
TFP=$(cat /proc/driver/nvidia/params 2>/dev/null | grep TemporaryFilePath | awk -F'"' '{print $2}')
if [[ "$TFP" == "/var/tmp" ]]; then
    ok "NVreg_TemporaryFilePath=/var/tmp"
else
    warn "NVreg_TemporaryFilePath is '${TFP:-not set}' (recommend /var/tmp)"
fi

# Summary
echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All checks passed. Suspend should work correctly.${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES check(s) failed. Fix the above before suspending.${RESET}"
fi
echo ""
CHECKEOF

chmod +x "$CHECK_SCRIPT"
success "Installed: $CHECK_SCRIPT"

# Add alias to user's bashrc
if [[ -f "$REAL_HOME/.bashrc" ]]; then
    if ! grep -q "check-suspend" "$REAL_HOME/.bashrc"; then
        echo "" >> "$REAL_HOME/.bashrc"
        echo "# nvidia-sleep-fix: run after apt upgrade to verify suspend chain" >> "$REAL_HOME/.bashrc"
        echo "alias check-suspend='sudo /usr/local/bin/check-suspend'" >> "$REAL_HOME/.bashrc"
        success "Added check-suspend alias to $REAL_HOME/.bashrc"
    fi
fi

header "Step 10: Rebuild initramfs"

info "Rebuilding initramfs for all kernels (this may take a minute)..."
update-initramfs -u -k all
success "initramfs rebuilt"

header "Installation Complete"

echo ""
echo -e "${BOLD}Summary of what was installed:${RESET}"
echo "  /etc/modprobe.d/nvidia-power-management.conf   — GPU suspend parameters"
echo "  /etc/systemd/system/systemd-suspend.service.d/ — Suspend dependency wiring"
echo "  /etc/systemd/system/systemd-resume.service.d/  — Resume dependency wiring"
echo "  /etc/systemd/system/nvidia-wakeup-disable.service — ACPI wakeup fix"
echo "  /etc/apt/apt.conf.d/99-nvidia-sleep-fix        — Auto initramfs rebuild hook"
echo "  /usr/local/bin/check-suspend                   — Health check tool"
if [[ -n "$DEFAULT_NIC" ]]; then
echo "  /etc/systemd/system/wol-enable.service         — Wake-on-LAN persistence"
fi
echo ""
echo -e "${BOLD}Your post-upgrade ritual going forward:${RESET}"
echo "  sudo apt upgrade"
echo "  check-suspend"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Reboot: sudo reboot"
echo "  2. After reboot: check-suspend"
echo "  3. Test suspend — GPU fans should be silent, blue light off"
echo "  4. After waking: journalctl -b | grep -iE 'nvidia-suspend|nvidia-resume'"
echo "     Look for: status=0/SUCCESS on both services"
echo ""
echo -e "${GREEN}${BOLD}Done. Sleep tight.${RESET}"
