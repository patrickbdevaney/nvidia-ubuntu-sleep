#!/usr/bin/env bash
# nvidia-sleep-fix: Clean uninstaller
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root: sudo bash uninstall.sh"; exit 1; fi

echo "Removing nvidia-sleep-fix..."

FILES=(
    /etc/modprobe.d/nvidia-power-management.conf
    /etc/systemd/system/systemd-suspend.service.d/nvidia.conf
    /etc/systemd/system/systemd-resume.service.d/nvidia.conf
    /etc/systemd/system/systemd-hibernate.service.d/nvidia.conf
    /etc/apt/apt.conf.d/99-nvidia-sleep-fix
    /usr/local/bin/check-suspend
    /usr/lib/systemd/system-sleep/wol-rearm.sh
)

systemctl disable --now nvidia-wakeup-disable.service 2>/dev/null || true
systemctl disable --now wol-enable.service 2>/dev/null || true
rm -f /etc/systemd/system/nvidia-wakeup-disable.service
rm -f /etc/systemd/system/wol-enable.service

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] && rm -f "$f" && echo "Removed: $f"
done

# Unhold driver if held
DRIVER_PKG=$(dpkg -l 'nvidia-driver-*' 2>/dev/null | awk '/^ii/{print $2}' | head -1)
[[ -n "$DRIVER_PKG" ]] && apt-mark unhold "$DRIVER_PKG" 2>/dev/null || true

systemctl daemon-reload
update-initramfs -u -k all

echo "Done. nvidia-sleep-fix removed. Reboot recommended."
