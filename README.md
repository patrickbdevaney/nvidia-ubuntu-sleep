# nvidia-sleep-fix

**Bulletproof NVIDIA GPU suspend/resume for Ubuntu/Linux.**

Fixes the problem where your GPU fans spin full blast, the blue LED stays on, and Wake-on-LAN stops working when the system is "asleep" — and keeps it fixed permanently across driver and kernel updates.

---

## Symptoms This Fixes

- GPU fans running at full speed during suspend
- Blue LED / RGB lighting staying on during suspend  
- System appearing suspended but GPU fully powered
- Wake-on-LAN unresponsive (because GPU holds PCIe awake)
- Suspend working fine, then silently breaking after `apt upgrade`

---

## Tested Configurations

| Component | Versions |
|-----------|----------|
| OS | Ubuntu 24.04 LTS, 24.10 |
| Kernel | 6.8.x, 6.11.x, 6.12.x |
| NVIDIA Driver | 550.x, 560.x, 570.x |
| GPU | RTX 3080, 3090, 4080, 4090 (any modern NVIDIA) |
| Motherboard | Gigabyte B550, X570, Z790; ASUS X570, Z690 |
| CPU platform | AMD Ryzen (AM4/AM5), Intel 12th/13th gen |

---

## Quick Start

```bash
git clone https://github.com/yourusername/nvidia-sleep-fix
cd nvidia-sleep-fix
sudo bash install.sh
sudo reboot
check-suspend   # run after reboot to verify
```

---

## What The Installer Does

The installer auto-detects your system and applies all relevant fixes. Here is every layer explained:

### Layer 1: NVIDIA Module Parameters
**File:** `/etc/modprobe.d/nvidia-power-management.conf`

```
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var/tmp
options nvidia-drm modeset=1
options nvidia-drm fbdev=1
```

**Why:** `NVreg_PreserveVideoMemoryAllocations=1` is the master switch. Without it, the NVIDIA driver does not save GPU video memory before suspend, so the GPU cannot power down — it stays on with fans at full speed. `/var/tmp` is used instead of `/tmp` because it persists across resume. These options are baked into the initramfs so they survive reboots.

---

### Layer 2: Systemd Suspend Dependency Wiring
**Files:** `/etc/systemd/system/systemd-suspend.service.d/nvidia.conf`  
`/etc/systemd/system/systemd-resume.service.d/nvidia.conf`

```ini
[Unit]
Wants=nvidia-suspend.service
After=nvidia-suspend.service
```

**Why:** The NVIDIA driver ships `nvidia-suspend.service` and `nvidia-resume.service`, which tell the GPU to save/restore state. These services are `enabled` but the `WantedBy=` wiring can silently break after driver or kernel updates, meaning they never actually run. These drop-in files force systemd to always invoke them in the correct order. This is the fix most commonly missing on broken systems.

---

### Layer 3: ACPI Wakeup Source Disabling
**File:** `/etc/systemd/system/nvidia-wakeup-disable.service`

**Why:** On AMD B550/X570 motherboards (Gigabyte especially), ACPI devices `GPP0` (PCIe bridge), `PTXH`, and `XHC0/XHC1` (USB controllers) are incorrectly marked as wakeup sources. This causes the system to immediately wake itself up after suspending, or prevents the PCIe bus from fully powering down — which keeps the GPU alive. The service disables them on every boot.

The installer auto-detects which wakeup sources are problematic on your specific board.

**To check manually:**
```bash
cat /proc/acpi/wakeup | grep -iE "GPP|PTXH|XHC"
# *disabled = good, *enabled = problem
```

---

### Layer 4: Conflicting Hook Removal
Custom sleep hooks in `/etc/systemd/system-sleep/` that use `nvidia-smi --gpu-reset` or attempt to manually manage GPU power state **conflict** with and break the canonical NVIDIA hook in `/usr/lib/systemd/system-sleep/nvidia`. The installer detects and backs up any such conflicts.

**The canonical hook** (`/usr/lib/systemd/system-sleep/nvidia`) calls `nvidia-sleep.sh` which writes to `/proc/driver/nvidia/suspend` — this is the correct, driver-supported mechanism.

---

### Layer 5: APT Post-Install Hook
**File:** `/etc/apt/apt.conf.d/99-nvidia-sleep-fix`

Automatically runs `update-initramfs -u -k all` after any NVIDIA package update. This ensures the modprobe parameters from Layer 1 are always baked into the new initramfs — without this, a driver update can silently undo the fix.

---

### Layer 6: Driver Version Hold
Prevents `apt upgrade` from silently jumping to a new major NVIDIA driver version that may have different suspend behavior. When you deliberately want a new major driver version, use the included upgrade helper.

---

### Layer 7: Wake-on-LAN Persistence
**Files:** `/etc/systemd/system/wol-enable.service`  
`/usr/lib/systemd/system-sleep/wol-rearm.sh`

WoL settings reset on every boot and sometimes after resume. The service re-arms it on boot; the sleep hook re-arms it after every resume.

---

## The check-suspend Command

Installed to `/usr/local/bin/check-suspend`. Run it after any `apt upgrade`:

```bash
sudo apt upgrade
check-suspend
```

It verifies every layer of the fix chain:

```
[OK]   NVreg_PreserveVideoMemoryAllocations=1
[OK]   nvidia-suspend.service is in suspend dependency tree
[OK]   nvidia-resume.service is enabled
[OK]   No problematic ACPI wakeup sources enabled
[OK]   No conflicting custom sleep hooks found
[OK]   Canonical NVIDIA sleep hook present and executable
[OK]   NVreg_TemporaryFilePath=/var/tmp

All checks passed. Suspend should work correctly.
```

If anything shows `[FAIL]`, it tells you exactly how to fix it.

---

## Upgrading NVIDIA Driver (CUDA version bump etc.)

Use the included helper to safely move to a new major driver version:

```bash
sudo bash upgrade-driver.sh 575
sudo reboot
check-suspend
```

This unhold → installs → re-verifies → re-holds in one shot.

---

## Diagnosing a Failed Suspend

If suspend breaks again after an OS or driver update, run this sequence:

```bash
# 1. Run the health check
check-suspend

# 2. Check the last suspend cycle logs
journalctl -b | grep -iE "nvidia-suspend|nvidia-resume|nvidia-sleep"
# Look for: status=0/SUCCESS on both services
# Bad sign: service never appears, or status=1/FAILURE

# 3. Check if the GPU received the suspend signal
cat /proc/driver/nvidia/suspend 2>/dev/null
# After a good suspend/resume cycle this may show: "resume"

# 4. Check wakeup sources
cat /proc/acpi/wakeup | grep -iE "GPP|PTXH|XHC"

# 5. Check for conflicting hooks
ls -la /etc/systemd/system-sleep/
ls -la /usr/lib/systemd/system-sleep/
```

---

## Uninstalling

```bash
sudo bash uninstall.sh
sudo reboot
```

---

## Why This Breaks After apt upgrade

Three common failure modes after an update:

1. **New kernel + DKMS rebuild** resets module parameter precedence. Fix: initramfs rebuild (Layer 5 handles this automatically).

2. **New driver package** re-writes `/usr/lib/systemd/system/nvidia-suspend.service` with a different `WantedBy=` that doesn't wire up correctly on your kernel. Fix: the drop-in files in Layer 2 override this regardless of what the package writes.

3. **New driver package** installs a new `/usr/lib/systemd/system-sleep/nvidia` that conflicts with a custom hook you wrote previously. Fix: Layer 4 backs up custom hooks; the canonical hook always wins.

---

## Contributing

If you have a motherboard/GPU combination that required additional fixes, please open a PR with:
- Your board vendor/model (`cat /sys/class/dmi/id/board_name`)
- Your problematic ACPI wakeup sources (`cat /proc/acpi/wakeup`)
- The fix that worked

The goal is for `install.sh` to auto-detect and handle every board's quirks.

---

## License

MIT
