# Troubleshooting Guide

## Step 1: Always Run check-suspend First

```bash
check-suspend
```

This diagnoses every layer of the fix chain in 2 seconds. Fix any `[FAIL]` items before suspending.

---

## Symptom: GPU fans spinning, blue light on during suspend

**Root cause:** the platform never reached S3, or suspend was aborted. Check the sleep state first:

```bash
cat /sys/power/mem_sleep          # [deep] = S3; [s2idle] = suspend-to-idle, where PCIe devices can stay powered
journalctl -b -1 | grep -iE "PM: suspend|ACPI: PM"   # did the last attempt complete?
```

On `s2idle`-only platforms the GPU stays powered unless it reaches D3 through runtime power management; see NVIDIA's driver README ("Configuring Power Management Support"). If the state is `deep` and the fans still spin, the system did not complete S3 (in S3 the slot loses main power); the journal shows where it stopped. Common NVIDIA-side causes are `nvidia-suspend.service` failing or never running, and `NVreg_PreserveVideoMemoryAllocations` not being active. Note also that RGB lighting on 5 V standby can stay lit in S3 by design unless the firmware's ErP/EuP option is enabled.

**Diagnose:**
```bash
# Is the parameter active?
cat /proc/driver/nvidia/params | grep PreserveVideoMemoryAllocations
# Should be: PreserveVideoMemoryAllocations: 1

# Did nvidia-suspend.service run during last suspend?
journalctl -b | grep nvidia-suspend
# Should show: nvidia-suspend.service ... status=0/SUCCESS
```

**Fix if parameter is 0:**
```bash
cat /etc/modprobe.d/nvidia-power-management.conf
# Should contain: options nvidia NVreg_PreserveVideoMemoryAllocations=1
# If missing, re-run install.sh or add it manually, then:
sudo update-initramfs -u -k all
sudo reboot
```

**Fix if nvidia-suspend.service never ran:**
```bash
systemctl list-dependencies systemd-suspend.service | grep nvidia
# If nvidia-suspend.service is NOT listed:
sudo mkdir -p /etc/systemd/system/systemd-suspend.service.d
sudo tee /etc/systemd/system/systemd-suspend.service.d/nvidia.conf << 'EOF'
[Unit]
Wants=nvidia-suspend.service
After=nvidia-suspend.service
EOF
sudo systemctl daemon-reload
```

---

## Symptom: System wakes up immediately after suspend

**Root cause:** An ACPI wakeup source (GPP0, PTXH, XHC0) is pulling it back awake.

**Diagnose:**
```bash
cat /proc/acpi/wakeup | grep -iE "GPP|PTXH|XHC"
# Any *enabled entries here are suspect
```

**Fix:**
```bash
sudo systemctl restart nvidia-wakeup-disable.service
cat /proc/acpi/wakeup | grep -iE "GPP|PTXH|XHC"
# Should all be *disabled now
```

If a source not covered by the service is enabled, add it:
```bash
sudo nano /etc/systemd/system/nvidia-wakeup-disable.service
# Add (writes TOGGLE, so guard on the current state):
# ExecStart=/bin/sh -c 'grep -q "^SOURCENAME[[:space:]].*[*]enabled" /proc/acpi/wakeup && echo SOURCENAME > /proc/acpi/wakeup || true'
sudo systemctl daemon-reload
sudo systemctl restart nvidia-wakeup-disable.service
```

---

## Symptom: Works, then breaks after apt upgrade

**Root cause:** A kernel or driver update reset something in the chain.

**Full re-arm (no reinstall needed):**
```bash
# Re-enable services
sudo systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service

# Verify drop-ins still exist
ls /etc/systemd/system/systemd-suspend.service.d/
ls /etc/systemd/system/systemd-resume.service.d/

# Rebuild initramfs
sudo update-initramfs -u -k all

# Reload systemd
sudo systemctl daemon-reload

# Run health check
check-suspend

sudo reboot
```

---

## Symptom: nvidia-suspend.service fails with error

**Diagnose:**
```bash
journalctl -b | grep -i "nvidia-suspend\|nvidia-sleep"
# Look for error codes or messages
```

**Common error: `/proc/driver/nvidia/suspend` not found**
```bash
ls /proc/driver/nvidia/
```
If `suspend` is missing, the driver module isn't fully loaded or `NVreg_PreserveVideoMemoryAllocations` isn't set.

**Common error: `nvidia-sleep.sh` not found**
```bash
ls -la /usr/bin/nvidia-sleep.sh
# If missing:
sudo apt install --reinstall nvidia-kernel-common-$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | cut -d. -f1)
```

---

## Symptom: Wake-on-LAN not working

WoL requires suspend to fully work first. If the GPU is still powered, the NIC may not be in the right state to respond to magic packets.

**Verify WoL is armed:**
```bash
sudo ethtool <your-nic> | grep Wake
# Should show: Wake-on: g
```

**Verify the service is running:**
```bash
systemctl status wol-enable.service
```

**Test WoL from another machine:**
```bash
# Install wakeonlan on the remote machine
sudo apt install wakeonlan
# Get the MAC address of the sleeping machine's NIC
wakeonlan <MAC-ADDRESS>
```

---

## Symptom: Resume is slow or hangs

**Likely cause:** The GPU has 24GB+ of VRAM (RTX 3090, 4090) and saving/restoring it takes time.

This is normal behavior with `NVreg_PreserveVideoMemoryAllocations=1`. The driver is saving and restoring all GPU memory. For a 3090 (24GB) expect 5-15 seconds on resume.

`NVreg_TemporaryFilePath=/var/tmp` puts the dump on disk (not tmpfs), so it does not consume system RAM. Resume time scales with the VRAM in use and the speed of that disk.

---

## Nuclear Option: Full Reinstall of This Fix

If everything is broken and you're not sure what's in what state:

```bash
sudo bash uninstall.sh
sudo reboot
sudo bash install.sh
sudo reboot
check-suspend
```

---

## Collecting Logs for a Bug Report

```bash
# Full suspend/resume log from current boot
journalctl -b | grep -iE "nvidia|suspend|sleep|acpi|wakeup" > /tmp/suspend-debug.log

# System info
nvidia-smi >> /tmp/suspend-debug.log
uname -r >> /tmp/suspend-debug.log
cat /proc/cmdline >> /tmp/suspend-debug.log
cat /proc/acpi/wakeup >> /tmp/suspend-debug.log
systemctl list-dependencies systemd-suspend.service >> /tmp/suspend-debug.log
cat /proc/driver/nvidia/params | grep -iE "Preserve|Temporary" >> /tmp/suspend-debug.log

cat /tmp/suspend-debug.log
```

Include this output when opening an issue.
