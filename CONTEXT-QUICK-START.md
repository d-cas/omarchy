# Omarchy Dracut Migration - Quick Start Context

**Last Updated:** 2025-10-20
**Current Branch:** `dracut-rebased` (based on `upstream/dev`)
**Status:** ✅ **COMPLETE SUCCESS** - Full MVP working with LUKS + SDDM autologin + FIDO2 enabled

---

## TL;DR - MISSION ACCOMPLISHED ✅

**Original Goal:** Migrate from mkinitcpio to dracut to fix FIDO2 multi-token unlock hangs during boot.

**Problems Solved:**
1. LUKS detection must happen in ISO live environment, not in chroot
2. Wrong JSON path prevented pre-archinstall detection
3. `pipefail` broke installation pipeline before post-install scripts ran
4. **Critical bug:** `basename` treated `[/@]` as glob pattern, breaking MAPPER_NAME extraction
5. SDDM setup accidentally removed during dracut rebase

**Solution (IMPLEMENTED & WORKING):**
- Detect LUKS UUID in ISO's `.automated_script.sh` (before AND after archinstall)
- Use parameter expansion `${var%%\[*}` instead of `basename` (avoids glob issues)
- Write UUID to `/mnt/.luks_uuid`
- Read from `/.luks_uuid` in chroot scripts (`setup-dracut.sh`, `limine-snapper.sh`)
- Generate correct `limine.conf` with dracut LUKS parameters
- Restore SDDM and keyring setup in installation flow

**Current Status - FULLY WORKING:**
- ✅ System boots and prompts for LUKS password
- ✅ dracut unlocks encrypted root successfully
- ✅ SDDM starts and auto-logs in
- ✅ Desktop environment (Hyprland) starts perfectly
- ✅ FIDO2 support enabled and ready for multi-token testing

**See Also:**
- CRITICAL-FINDINGS.md - Complete root cause analysis
- LUKS-DRACUT-IMPLEMENTATION.md - Full technical documentation
- TROUBLESHOOTING-WORKFLOW.md - Debugging procedures

---

## Project Overview

### What is Omarchy?
- Arch Linux-based distribution focused on developer experience
- Uses archinstall for installation
- Uses Limine bootloader + dracut for initramfs

### Migration Goal
Migrate from **mkinitcpio** to **dracut** to fix FIDO2 multi-token unlock hangs during boot.

### Repository Structure
- **Main repo:** `d-cas/omarchy` (fork of `basecamp/omarchy`)
- **Working branch:** `dracut-rebased` (rebased on `upstream/dev`)
- **ISO repo:** `/home/dcas/truenas/dev-projects/omarchy_repos/omarchy-iso`
- **Main repo:** `/mnt/truenas/dev-projects/omarchy_repos/omarchy`

---

## The Boot Flow Problem

### Correct Boot Flow (What Should Happen)
1. Limine bootloader loads
2. Reads `limine.conf` with boot parameters
3. Loads kernel + dracut initramfs
4. Dracut reads `rd.luks.uuid=<LUKS_UUID>` parameter
5. Unlocks LUKS container with password/FIDO2
6. Mounts encrypted root filesystem
7. Boots into system

### What Was Happening (Before Fix)
1. archinstall creates `limine.conf` with **mkinitcpio syntax** (wrong for dracut)
2. Our scripts run INSIDE chroot and try to detect LUKS
3. LUKS detection **fails in chroot** (findmnt, cryptsetup status don't work reliably)
4. Scripts fall back to filesystem UUID instead of LUKS UUID
5. `limine.conf` gets: `root=UUID=a023dd39-bd3e-...` (filesystem UUID)
6. Should have: `rd.luks.uuid=68ba123d-... rd.luks.name=...=root root=/dev/mapper/root`
7. Dracut emergency shell: "device does not exist"

### Why Detection Failed in Chroot
From Grok AI analysis:
- `findmnt -n -o SOURCE /` doesn't always show `/dev/mapper/root` in chroot
- `cryptsetup status root` may fail if mapper isn't active in chroot context
- Scanning `/sys/class/block/` generically doesn't trace back to root device properly
- The scripts assumed they could detect LUKS the same way in chroot as in live environment

---

## The Solution We Implemented

### Three-Part Fix

#### 1. Pre-Chroot Detection Script
**File:** `install/preflight/detect-luks.sh`

**When it runs:** BEFORE chroot (in live ISO environment)

**What it does:**
- Scans all block devices for LUKS containers
- Checks if `/mnt` (installation target) is on encrypted device
- Writes results to `/.luks_uuid` and `/.luks_device`
- These files persist into the chroot environment

**Key methods:**
```bash
# Method 1: Check current root mapper
cryptsetup status /dev/mapper/root

# Method 2: Scan all block devices
for blockdev in /sys/class/block/*; do
  cryptsetup isLuks "$devname" && cryptsetup luksUUID "$devname"
done

# Method 3: Check /mnt mount
findmnt -n -o SOURCE /mnt | cryptsetup status
```

#### 2. Modified setup-dracut.sh
**What changed:** Instead of trying to detect LUKS in chroot, reads from `/.luks_uuid`

**Key section:**
```bash
if [ -f "/.luks_uuid" ]; then
  luks_uuid=$(cat /.luks_uuid)
  cmdline="rd.luks.uuid=$luks_uuid rd.luks.name=${luks_uuid}=root root=/dev/mapper/root rw"
else
  # Unencrypted fallback
  cmdline="root=UUID=$root_uuid rw"
fi
```

**Also does:** "Hostile takeover" - completely overwrites archinstall's broken `limine.conf`

#### 3. Modified limine-snapper.sh
**What changed:** Same as setup-dracut.sh - reads from `/.luks_uuid` instead of detecting

---

## File Locations & Key Scripts

### Installation Flow
1. **Preflight** (before chroot):
   - `install/preflight/detect-luks.sh` - Detects LUKS, writes to `/.luks_uuid`
   - `install/preflight/disable-dracut-hooks.sh` - Prevents premature initramfs generation

2. **Login** (inside chroot):
   - `install/login/limine-snapper.sh` - Creates `/etc/default/limine`, initial `limine.conf`
   - `install/login/setup-dracut.sh` - Hostile takeover of `limine.conf`, generates dracut initramfs
   - `install/login/plymouth.sh` - Plymouth boot splash setup

3. **Dracut Config Files:**
   - `install/config/dracut/10-omarchy.conf` - Base dracut config (FIDO2 module currently disabled)
   - `install/config/dracut/20-apple-t2.conf` - Apple T2 hardware support
   - `install/config/dracut/21-apple-spi.conf` - Apple SPI keyboard support
   - `install/config/dracut/30-nvidia.conf` - NVIDIA driver support

### Key Package Changes
**File:** `install/omarchy-other.packages`

**Changes:**
- Removed: `limine-mkinitcpio-hook`
- Added: `dracut`, `mkinitcpio` (for archinstall compatibility), `jre17-openjdk` (for limine-snapper-sync)

---

## How to Build & Test

### Build ISO
```bash
cd /home/dcas/truenas/dev-projects/omarchy_repos/omarchy-iso
./bin/omarchy-iso-make --no-cache
```

The `--no-cache` is important to force Docker to pull latest code from GitHub.

### Boot ISO in VM
```bash
./bin/omarchy-iso-boot release/omarchy-dracut-rebased.iso
```

### What to Watch During Installation
Look for these BREADCRUMB messages in the installation output:

**Early (preflight phase):**
```
Pre-chroot: Detecting LUKS encryption...
✓ LUKS encryption detected
  Device: /dev/vda2
  UUID: 68ba123d-e341-4a7f-8677-0c8903ab1a2a
✓ Saved LUKS info to /mnt/.luks_uuid
```

**Later (setup-dracut.sh phase):**
```
BREADCRUMB: Reading LUKS info from pre-chroot detection
BREADCRUMB: Found pre-detected LUKS info:
BREADCRUMB:   UUID: 68ba123d-e341-4a7f-8677-0c8903ab1a2a
BREADCRUMB: *** ENCRYPTED ROOT PATH ***
BREADCRUMB: Generated LUKS cmdline: rd.luks.uuid=68ba123d-... rd.luks.name=...=root root=/dev/mapper/root
BREADCRUMB: Performing HOSTILE TAKEOVER of /boot/EFI/BOOT/limine.conf...
BREADCRUMB: ✓ /boot/EFI/BOOT/limine.conf OVERWRITTEN successfully
```

### How to Inspect Installed System
```bash
# Mount the qcow2 image
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 /tmp/omarchy-iso-boot.qcow2
sudo fdisk -l /dev/nbd0

# Unlock LUKS and mount (btrfs with subvolumes)
sudo cryptsetup open /dev/nbd0p2 omarchy_root
sudo mkdir -p /mnt/omarchy_check
sudo mount -o subvol=@ /dev/mapper/omarchy_root /mnt/omarchy_check
sudo mount /dev/nbd0p1 /mnt/omarchy_check/boot

# Check the limine.conf
cat /mnt/omarchy_check/boot/EFI/limine/limine.conf

# Should show:
# cmdline: rd.luks.uuid=68ba123d-... rd.luks.name=...=root root=/dev/mapper/root rw

# Cleanup when done
sudo umount /mnt/omarchy_check/boot
sudo umount /mnt/omarchy_check
sudo cryptsetup close omarchy_root
sudo qemu-nbd --disconnect /dev/nbd0
```

---

## Expected Behavior After Fix

### Successful Boot
1. VM boots from installed disk
2. Shows LUKS password prompt (or FIDO2 prompt if re-enabled)
3. Unlocks encrypted root successfully
4. Boots into Omarchy system

### If It Fails
Check the `cmdline:` in limine.conf - if it still shows filesystem UUID instead of LUKS UUID, the detection script didn't run or failed.

---

## Git Workflow

### Branches
- `master` - user's fork master (outdated)
- `dracut` - original dracut work (outdated, has 25 commits)
- `dracut-rebased` - **CURRENT** - rebased on `upstream/dev` with clean implementation

### Recent Commits
```
ef256da - fix: restore SDDM and keyring setup during installation
cb3ffb6 - docs: complete LUKS detection solution documentation
1c76852 - fix: detect LUKS UUID before chroot to avoid chroot detection failures
3adf5f7 - feat: migrate from mkinitcpio to dracut for improved FIDO2 multi-token support
```

### Remotes
- `origin` - `d-cas/omarchy` (your fork)
- `upstream` - `basecamp/omarchy` (original repo - fully synced with upstream/dev)

### ISO Repository
- **Fork:** `d-cas/omarchy-iso` (forked from `omacom-io/omarchy-iso`)
- **Branch:** `dracut` (contains all 5 LUKS detection fixes)
- **Pushed:** All changes available on GitHub

---

## Current Status - COMPLETE ✅

### All Systems Working
- ✅ Pre-chroot LUKS detection implemented and tested
- ✅ Hostile takeover fix in place
- ✅ Clean rebase on upstream/dev (fully synced)
- ✅ SDDM autologin working perfectly
- ✅ FIDO2 enabled in dracut config
- ✅ Full system boots: LUKS unlock → SDDM → Hyprland desktop

### FIDO2 Status
**ENABLED** in `install/config/dracut/10-omarchy.conf`:
```bash
add_dracutmodules+=" crypt systemd-cryptsetup fido2 "
install_items+=" /usr/lib/cryptsetup/libcryptsetup-token-systemd-fido2.so "
```

Ready for multi-token FIDO2 testing!

### Next Steps
1. ✅ ~~Verify password unlock works~~ - DONE
2. ✅ ~~Re-enable FIDO2 module~~ - ALREADY ENABLED
3. 🎯 **Test multi-token FIDO2 scenario** (the original goal!)
4. 🎯 Consider PR to upstream if desired
5. 🎯 Merge `dracut-rebased` → `dracut` → potentially upstream

---

## Common Debugging Commands

### Check LUKS UUID
```bash
# From live environment or mounted qcow2
sudo cryptsetup luksUUID /dev/vda2  # Replace with actual device

# Should return something like:
# 68ba123d-e341-4a7f-8677-0c8903ab1a2a
```

### Check Filesystem UUID
```bash
sudo blkid /dev/mapper/root

# Shows filesystem UUID (the WRONG one for boot params):
# UUID="a023dd39-bd3e-47d8-82bc-1428986ddf08"
```

### Check What's Actually Mounted
```bash
findmnt -n -o SOURCE,UUID /
# Shows: /dev/mapper/root a023dd39-bd3e-47d8-82bc-1428986ddf08
```

---

## Important Realizations from Debugging Sessions

### "Hostile Takeover" Strategy
Initially tried to APPEND to archinstall's limine.conf. **This failed** because:
- archinstall creates limine.conf BEFORE our scripts run
- It uses mkinitcpio-style `cryptdevice=PARTUUID=...` parameters
- Limine loads the FIRST entry, so archinstall's broken entry wins

**Solution:** Completely OVERWRITE the entire limine.conf file with dracut-compatible config.

### Chroot Detection is Fundamentally Broken
Spent several sessions trying to improve LUKS detection logic inside chroot:
- Added better findmnt usage
- Added /proc/mounts fallback
- Added /sys/class/block scanning
- Added extensive DEBUG logging

**All failed** because chroot fundamentally limits what these tools can see.

**Real solution:** Don't detect in chroot at all. Detect before chroot, pass through a file.

### Repository Confusion
Early on, had TWO clones of the same repo:
- `omarchy` (older, on master)
- `omarchy-dracut` (newer, on dracut branch)

Modified the wrong one, lost 5 days of work, had to restore from git.

**Resolution:** Consolidated to single `omarchy` directory on `dracut-rebased` branch.

---

## Quick Reference: What Each Script Does

| Script | Phase | Purpose |
|--------|-------|---------|
| `detect-luks.sh` | Preflight (pre-chroot) | Detect LUKS UUID, write to `/.luks_uuid` |
| `disable-dracut-hooks.sh` | Preflight | Prevent dracut pacman hooks from running during install |
| `limine-snapper.sh` | Login (in-chroot) | Create initial bootloader config, install limine-snapper-sync |
| `setup-dracut.sh` | Login (in-chroot) | Generate dracut initramfs, hostile takeover of limine.conf |
| `plymouth.sh` | Login (in-chroot) | Configure Plymouth boot splash |

---

## If Starting Fresh

Paste this entire document + say:
> "I'm working on the Omarchy dracut migration. We just implemented a fix for LUKS UUID detection in chroot. The ISO is currently installing. What's the current status and what should I watch for?"

The LLM will immediately know:
- What project you're working on
- The core problem we solved
- What phase you're in
- What to check next

---

## File System Structure Reminder

The installed system uses **btrfs with subvolumes**:
```
/dev/vda1          → /boot (FAT32, EFI partition)
/dev/vda2          → LUKS container (UUID: 68ba123d-...)
  └─ /dev/mapper/root → btrfs volume (UUID: a023dd39-...)
       ├─ @ subvolume     → / (root)
       ├─ @home subvolume → /home
       ├─ @log subvolume  → /var/log
       └─ @pkg subvolume  → /var/cache/pacman/pkg
```

When mounting to inspect:
```bash
mount -o subvol=@ /dev/mapper/root /mnt  # NOT just mount /dev/mapper/root
```

---

**End of Quick Start Context**

For detailed session-by-session history, see `PROJECT-STATUS.md` and `CONTEXT.md` in the repository.
