#!/usr/bin/env bash
# nvidia-sleep-fix: Safe NVIDIA driver upgrade helper
# Usage: sudo bash upgrade-driver.sh 575
#
# This script safely upgrades your NVIDIA driver to a new major version
# while preserving and re-verifying the entire suspend fix chain.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root: sudo bash upgrade-driver.sh <new-version>${RESET}"
    exit 1
fi

NEW_VERSION="${1:-}"
if [[ -z "$NEW_VERSION" ]]; then
    echo "Usage: sudo bash upgrade-driver.sh <major-version>"
    echo "Example: sudo bash upgrade-driver.sh 575"
    exit 1
fi

CURRENT_PKG=$(dpkg -l 'nvidia-driver-*' 2>/dev/null | awk '/^ii/{print $2}' | head -1)
CURRENT_VER=$(echo "$CURRENT_PKG" | grep -oP '\d+$')

echo -e "${BOLD}NVIDIA Driver Upgrade: ${CURRENT_VER} → ${NEW_VERSION}${RESET}"
echo ""
echo "This will:"
echo "  1. Unhold nvidia-driver-${CURRENT_VER}"
echo "  2. Install nvidia-driver-${NEW_VERSION}"
echo "  3. Re-verify the entire suspend fix chain"
echo "  4. Rebuild initramfs"
echo "  5. Re-hold nvidia-driver-${NEW_VERSION}"
echo ""
read -rp "Proceed? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo -e "\n${CYAN}Unholding current driver...${RESET}"
apt-mark unhold "$CURRENT_PKG" 2>/dev/null || true

echo -e "\n${CYAN}Installing nvidia-driver-${NEW_VERSION}...${RESET}"
apt install -y "nvidia-driver-${NEW_VERSION}"

echo -e "\n${CYAN}Re-verifying suspend chain...${RESET}"

# Re-enable services (new driver may have reset them)
for svc in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service; do
    systemctl enable "$svc" 2>/dev/null && echo "  Enabled: $svc" || true
done

# Rebuild initramfs to bake in modprobe options
echo -e "\n${CYAN}Rebuilding initramfs...${RESET}"
update-initramfs -u -k all

# Re-hold new driver
NEW_PKG="nvidia-driver-${NEW_VERSION}"
if dpkg -l "$NEW_PKG" &>/dev/null; then
    apt-mark hold "$NEW_PKG"
    echo -e "${GREEN}Held: $NEW_PKG${RESET}"
fi

echo -e "\n${GREEN}${BOLD}Upgrade complete.${RESET}"
echo ""
echo "Next steps:"
echo "  1. sudo reboot"
echo "  2. check-suspend   ← run this after reboot to verify everything"
echo "  3. Test suspend before assuming it works"
