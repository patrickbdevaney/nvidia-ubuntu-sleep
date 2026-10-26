# Board-Specific Quirks

This document tracks ACPI wakeup-source issues by motherboard family, as reported by
users. Entries are not independently verified; device names and PCI addresses vary
by board revision and firmware version. The installer detects enabled sources at
install time; this file is a reference.

## AMD Platforms

### Gigabyte B550 (AORUS Elite, Pro, Ultra etc.)
**Problematic wakeup sources:** `GPP0`, `PTXH`, `XHC0`
- `GPP0` = PCIe bridge at `0000:00:01.1` — keeps GPU PCIe lane alive
- `PTXH` = USB controller bridge at `0000:02:00.0`
- `XHC0` = USB host controller at `0000:09:00.3`

**Symptom:** GPU fans spin on suspend; system may immediately wake itself.

---

### Gigabyte X570 (AORUS, Gaming X etc.)
**Problematic wakeup sources:** `GPP0`, `GP17`, `XHC0`
- Similar to B550 but `GP17` instead of `PTXH` on some BIOSes

---

### ASUS X570 (ROG Strix, TUF, Prime)
**Problematic wakeup sources:** `XHC0`, `XHC1` (on some BIOSes)
- Generally better ACPI implementation than Gigabyte
- May not require wakeup source disabling at all

---

### ASRock B550 / X570
**Problematic wakeup sources:** `GPP0`, `XHCI`
- Use `XHCI` instead of `XHC0` on some board revisions

---

## Intel Platforms

### Gigabyte Z790 / Z690
**Problematic wakeup sources:** `XHCI`, `PTXH`
- Intel PCIe topology differs from AMD; `GPP0` usually not present

---

### ASUS Z790 / Z690 (ROG, TUF)
**Generally:** Good ACPI implementation, wakeup source disabling often not needed.
- If issues persist, check for `XHCI` being enabled.

---

## How to Identify Your Wakeup Sources

```bash
# Show all wakeup sources and their current state
cat /proc/acpi/wakeup

# Column meanings:
# Column 1: ACPI device name
# Column 2: Sleep state (S3/S4)
# Column 3: *enabled or *disabled
# Column 4: PCI address

# To manually disable a source (resets on reboot, use the service for persistence):
echo SOURCENAME | sudo tee /proc/acpi/wakeup

# Note: writing to this file TOGGLES the state, it does not set it.
# If currently enabled, writing the name disables it.
# If currently disabled, writing the name re-enables it.
# The wakeup-disable service accounts for this: each ExecStart writes only
# if the source is currently *enabled, so restarting the service is safe.
```

---

## Contributing Your Board

Open a PR or issue with the output of:
```bash
cat /proc/acpi/wakeup
cat /sys/class/dmi/id/board_vendor
cat /sys/class/dmi/id/board_name
```
And note which sources needed to be disabled for suspend to work.
