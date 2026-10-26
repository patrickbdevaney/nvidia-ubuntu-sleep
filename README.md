# nvidia-ubuntu-sleep

Durable suspend and resume for NVIDIA proprietary drivers on Ubuntu desktops: module parameters, systemd unit
wiring, ACPI wakeup control and package-update safeguards, installed as one unit and verified with one command.

---

## NAME

**nvidia-sleep-fix**: install, verify and maintain the configuration that NVIDIA GPUs need to suspend (S3) and
resume reliably under Ubuntu, and keep that configuration intact across `apt`, DKMS, kernel and driver upgrades.

## SYNOPSIS

```sh
sudo bash install.sh                      # detect, confirm, install; then reboot
check-suspend                             # verify every layer; exit status 0 if all pass
sudo bash upgrade-driver.sh <major>       # change driver branch, e.g. 575, preserving the configuration
sudo bash uninstall.sh                    # remove installed files; then reboot
```

## DESCRIPTION

On a correctly configured system, the NVIDIA driver saves video memory before the platform enters S3 and restores it
on resume. It does this through `nvidia-suspend.service`, `nvidia-resume.service` and `nvidia-hibernate.service`,
which write to `/proc/driver/nvidia/suspend`. That path needs three things to line up:
- module parameters that are only read when the module loads, often from the initramfs;
- systemd ordering supplied by the driver package;
- firmware wakeup behavior that differs between board vendors.

Any of these can drift independently after a kernel, DKMS or driver update.

Typical symptoms of a broken chain:
- fans and lighting stay on while the system appears suspended;
- the system wakes immediately after suspending;
- the display is corrupted or black after resume;
- Wake-on-LAN stops responding;
- suspend works until the next `apt upgrade`.

`install.sh` reports the detected driver, package, kernel, GPU, board and network interface, and asks for confirmation.
It then installs the components below. Every file it writes is under `/etc`, `/usr/local` or the systemd sleep-hook
directory, and is listed under [FILES](#files).

### Components

| # | Component | Mechanism |
|--:|---|---|
| 1 | Module parameters | `/etc/modprobe.d/nvidia-power-management.conf`: `NVreg_PreserveVideoMemoryAllocations=1`, `NVreg_TemporaryFilePath=/var/tmp`, `nvidia-drm modeset=1`, `nvidia-drm fbdev=1` |
| 2 | Driver sleep services | `systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate` |
| 3 | Unit ordering | Drop-ins that make `systemd-suspend.service` and `systemd-hibernate.service` `Wants=` and `After=` the corresponding NVIDIA service, independent of the package's `[Install]` section |
| 4 | Conflicting hooks | Known custom hooks in `/etc/systemd/system-sleep/` (`nvidia-suspend.sh`, `nvidia-fix.sh`, `gpu-sleep.sh`) are renamed to `*.bak.<date>` |
| 5 | ACPI wakeup sources | `nvidia-wakeup-disable.service` disables PCIe and USB wakeup sources (`GPP*`, `PTXH`, `XHC*`) that are enabled at install time, or GPP0, PTXH and XHC0 if none are |
| 6 | Wake-on-LAN (optional) | `wol-enable.service` and a post-resume hook run `ethtool -s <nic> wol g` on the default-route interface |
| 7 | initramfs refresh | A `DPkg::Post-Invoke` hook runs `update-initramfs -u -k all` (see [CAVEATS](#caveats)) |
| 8 | Driver hold (optional, prompted) | `apt-mark hold nvidia-driver-<N>` prevents unattended branch changes |
| 9 | Verification | `/usr/local/bin/check-suspend` |

**Why each parameter is set:**
- **`NVreg_PreserveVideoMemoryAllocations=1`** turns on the driver's full video-memory save and restore. Without it,
  only essential state is preserved, and resume can return a corrupted or black display, especially under Wayland
  compositors.
- **`NVreg_TemporaryFilePath`** sets where the dump is written. It must be a disk-backed filesystem with free space
  at least equal to the VRAM in use. A tmpfs would hold the dump in system RAM and cannot survive hibernation.
- **`modeset=1` and `fbdev=1`** enable kernel modesetting and the DRM framebuffer device. These are the defaults
  expected by current GNOME and Wayland sessions. `fbdev` requires driver 545 or later.

## REQUIREMENTS

| Item | Requirement |
|---|---|
| Distribution | Ubuntu 24.04 LTS or 24.10 (Debian-family `apt`/`dpkg`, `initramfs-tools`, systemd) |
| Driver | NVIDIA proprietary or open kernel modules, packaged as `nvidia-driver-<N>`, branch 550 or later; `nvidia-smi` present |
| Platform | x86-64 desktop with ACPI S3 (`deep`) available; see [PLATFORM NOTES](#platform-notes) |
| Privileges | root (`sudo`) |
| Optional | `ethtool` (Wake-on-LAN) |

**Configurations the scripts were written against:**

| Component | Range |
|---|---|
| Kernel | 6.8, 6.11, 6.12 |
| Driver | 550, 560, 570 |
| GPU | GeForce RTX 30 and 40 series |
| Boards | Gigabyte B550, X570, Z790; ASUS X570, Z690 |
| CPUs | AMD Ryzen (AM4/AM5); Intel 12th and 13th generation |

Per-configuration test logs are not included. Treat this as the intended scope, not a certification matrix.

## INSTALLATION

```sh
git clone https://github.com/patrickbdevaney/nvidia-ubuntu-sleep
cd nvidia-ubuntu-sleep
sudo bash install.sh
sudo reboot
check-suspend
```

**Then test one suspend cycle and inspect it:**

```sh
systemctl suspend
# after waking:
journalctl -b | grep -E 'nvidia-(suspend|resume)\.service'     # expect status=0/SUCCESS for both
```

## FILES

| Path | Purpose | Removed by `uninstall.sh` |
|---|---|:-:|
| `/etc/modprobe.d/nvidia-power-management.conf` | Module parameters (component 1) | yes |
| `/etc/systemd/system/systemd-suspend.service.d/nvidia.conf` | Suspend ordering | yes |
| `/etc/systemd/system/systemd-hibernate.service.d/nvidia.conf` | Hibernate ordering | yes |
| `/etc/systemd/system/systemd-resume.service.d/nvidia.conf` | Resume drop-in (inert; see [BUGS](#bugs)) | yes |
| `/etc/systemd/system/nvidia-wakeup-disable.service` | ACPI wakeup control | yes |
| `/etc/systemd/system/wol-enable.service` | Wake-on-LAN at boot | yes |
| `/usr/lib/systemd/system-sleep/wol-rearm.sh` | Wake-on-LAN after resume | yes |
| `/etc/apt/apt.conf.d/99-nvidia-sleep-fix` | initramfs refresh hook | yes |
| `/usr/local/bin/check-suspend` | Health check | yes |
| `~/.bashrc` (invoking user) | `alias check-suspend='sudo /usr/local/bin/check-suspend'` | **no** |
| `/etc/systemd/system-sleep/*.bak.<date>` | Renamed conflicting hooks | **no**, and not restored |

Files the scripts read but do not modify include `/proc/driver/nvidia/params`, `/proc/acpi/wakeup`,
`/usr/lib/systemd/system-sleep/nvidia` and `/sys/class/dmi/id/board_{vendor,name}`.

## COMMANDS

### check-suspend

A read-only verification of the chain. Each check prints `[OK]`, `[WARN]` or `[FAIL]`, and every `[FAIL]` comes with
a remediation line.

| Check | Pass condition |
|---|---|
| Video-memory preservation | `PreserveVideoMemoryAllocations: 1` in `/proc/driver/nvidia/params` |
| Suspend ordering | `nvidia-suspend.service` appears in `systemctl list-dependencies systemd-suspend.service` |
| Resume service | `nvidia-resume.service` is enabled |
| ACPI wakeup | None of GPP0, GPP1, PTXH, XHC0 or XHC1 is `*enabled` |
| Hook conflicts | No known conflicting hook in `/etc/systemd/system-sleep/` |
| Driver hook | `/usr/lib/systemd/system-sleep/nvidia` exists and is executable |
| Temporary file path | `TemporaryFilePath` is `/var/tmp` (`[WARN]` only) |

**Exit status:** 0 if every check passed, 1 otherwise. Run it after every `apt upgrade` that touches the kernel or the
driver.

### upgrade-driver.sh *major*

Changes driver branch in one step:
1. unholds the current `nvidia-driver-<N>`;
2. installs `nvidia-driver-<major>`;
3. re-enables the three NVIDIA sleep services;
4. rebuilds the initramfs for all kernels;
5. holds the new package.

Reboot afterwards and run `check-suspend`.

### uninstall.sh

Disables and removes the installed services, drop-ins, hooks and configuration listed under [FILES](#files), and
unholds the driver package. It then reloads systemd and rebuilds the initramfs. Reboot afterwards.

## DIAGNOSTICS

Work from the platform up:

```sh
cat /sys/power/mem_sleep                      # [deep] = S3; [s2idle] = suspend-to-idle
journalctl -b -1 | grep -E 'PM: suspend|ACPI: PM'                 # did the last suspend complete?
journalctl -b | grep -E 'nvidia-(suspend|resume|hibernate)\.service'
grep -E 'PreserveVideoMemoryAllocations|TemporaryFilePath' /proc/driver/nvidia/params
cat /proc/acpi/wakeup                         # *enabled sources can wake the system
systemctl list-dependencies systemd-suspend.service | grep -i nvidia
ls -l /etc/systemd/system-sleep/ /usr/lib/systemd/system-sleep/
```

Symptom-by-symptom procedures and a log-collection script for bug reports are in
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## PLATFORM NOTES

Hardware and firmware cause most suspend failures that survive a correct driver configuration.

| Hazard | Effect | Action |
|---|---|---|
| **Sleep state is `s2idle`, not `deep`** | The platform never enters S3; PCIe devices, including the GPU, can stay powered | Check `/sys/power/mem_sleep`. Prefer `deep` where firmware offers it (`mem_sleep_default=deep`). On `s2idle`-only systems, see the S0ix and runtime-D3 settings in NVIDIA's driver README; this repository does not configure them |
| **ACPI wakeup sources marked enabled by firmware** | Immediate wake after suspend. Typical on AMD 500-series boards: GPP0 (PCIe root port), PTXH and XHC* (USB) | Handled by `nvidia-wakeup-disable.service`; per-board notes in [`docs/BOARD-QUIRKS.md`](docs/BOARD-QUIRKS.md) |
| **5 V standby rails** | RGB lighting, and on some boards USB power, stay on in S3 by design | Firmware ErP/EuP setting; not a driver fault |
| **Wake-on-LAN** | Needs the NIC armed after every boot and resume, and firmware support enabled | Component 6; also enable "Wake on LAN" or "Power On by PCI-E" in firmware |
| **Large VRAM** | Suspend and resume take longer in proportion to VRAM in use (seconds on 24 GB cards) | Expected; keep `TemporaryFilePath` on fast local storage |
| **Secure Boot with DKMS** | A rebuilt module that is not signed with an enrolled MOK will not load after a kernel update | Enroll the DKMS signing key (`mokutil`); outside this repository's scope |
| **Hybrid graphics (laptops)** | Different power-management path (runtime D3, PRIME) | Not covered by these scripts |

## CAVEATS

- **`/proc/acpi/wakeup` toggles on write.** Writing a device name flips its state. `nvidia-wakeup-disable.service`
  writes only when the source is currently `*enabled`, so it is safe to restart. Manual writes are not.
- **The initramfs hook runs after every dpkg transaction** while any `nvidia-*` package is installed, not only after
  NVIDIA updates. It is redundant with the initramfs rebuild that kernel installation already performs, and it makes
  every `apt` operation slower. Remove `/etc/apt/apt.conf.d/99-nvidia-sleep-fix` if that cost matters.
- **A held driver package receives no updates**, including security point releases within its branch, and can hold
  back its dependencies. Check `apt-mark showhold` when NVIDIA publishes a security bulletin, and change branch with
  `upgrade-driver.sh`.
- **Module parameters take effect only when the module loads.** After editing the modprobe file, rebuild the initramfs
  and reboot. Reloading the module from a desktop session is not supported.

## BUGS

- The drop-in for `systemd-resume.service` is inert: no unit of that name exists on Ubuntu 24.04 (systemd 255).
  Resume ordering is supplied by `nvidia-resume.service` itself (`After=systemd-suspend.service`).
- `uninstall.sh` does not remove the `~/.bashrc` alias and does not restore renamed `*.bak.<date>` hooks.
- `check-suspend` checks only a fixed list of wakeup-source names.

Report issues with the output of `docs/TROUBLESHOOTING.md` § "Collecting Logs for a Bug Report", plus
`cat /sys/class/dmi/id/board_{vendor,name}`.

## SEE ALSO

- NVIDIA Accelerated Linux Graphics Driver README, chapter "Configuring Power Management Support"
- systemd-suspend.service(8), systemd.unit(5), systemd.service(5), systemctl(1)
- modprobe.d(5), update-initramfs(8), dkms(8)
- apt-mark(8), apt.conf(5), dpkg(1)
- ethtool(8)
- Linux kernel documentation: `admin-guide/pm/sleep-states`

## CONTRIBUTING

Board coverage grows from reports. Open an issue or pull request with:
- `cat /sys/class/dmi/id/board_vendor /sys/class/dmi/id/board_name`;
- the BIOS version;
- `cat /proc/acpi/wakeup`, before and after the fix;
- which sources had to be disabled;
- the driver branch and kernel.

## LICENSE

MIT. See [`LICENSE`](LICENSE).
