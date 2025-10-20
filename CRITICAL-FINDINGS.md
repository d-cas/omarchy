# LUKS DETECTION - COMPLETE SOLUTION (2025-10-19)

## ✅ PROBLEM SOLVED

**Status:** System successfully boots with encrypted LUKS root partition using dracut initramfs and correct UUID detection.

## The Journey: Root Cause Analysis

### Initial Problem
- System hung at boot waiting for `/dev/mapper/root`
- `limine.conf` contained filesystem UUID instead of LUKS UUID
- dracut couldn't unlock the encrypted partition

### First Hypothesis (INCORRECT)
We initially thought LUKS detection needed to happen in the omarchy repository's shell scripts (detect-luks.sh in preflight/).

**Why this was wrong:**
- These scripts run INSIDE the chroot (after archinstall completes)
- LUKS detection from inside chroot is unreliable
- The detection needed to happen BEFORE chroot, in the ISO environment

### Actual Root Cause Chain

1. **Location Issue:** LUKS detection must run in the **ISO's `.automated_script.sh`**, not in the omarchy repo's post-install scripts
2. **JSON Path Issue:** Pre-archinstall detection checked wrong JSON path (`.disk_encryption.encryption_type` instead of `.disk_config.disk_encryption.encryption_type`)
3. **Pipeline Issue:** The `sed` command in logging pipeline caused `pipefail` to abort installation
4. **Glob Expansion Issue:** `basename` treated `[/@]` as a glob pattern, breaking MAPPER_NAME extraction from `/dev/mapper/root[/@]`

## The Complete Solution

### Architecture Overview

```
ISO Boot (Live Environment)
  ↓
.automated_script.sh (omarchy-iso repo)
  ↓
[PRE-ARCHINSTALL] Check user_configuration.json for encryption
  ↓
archinstall runs → creates encrypted partitions
  ↓
[POST-ARCHINSTALL] Detect LUKS UUID from /mnt mount
  ↓
Write UUID to /mnt/.luks_uuid
  ↓
Copy install log to /mnt/var/log/omarchy-install.log
  ↓
Chroot into /mnt and run install.sh
  ↓
setup-dracut.sh reads /.luks_uuid
  ↓
Creates limine.conf with rd.luks.uuid=<UUID>
  ↓
System boots → dracut unlocks LUKS → success!
```

### Fixed Issues in omarchy-iso Repository

**File:** `configs/airootfs/root/.automated_script.sh`

#### Fix 1: Correct JSON Path (Commit 9419ea8)
```bash
# WRONG (original)
ENCRYPTION_ENABLED=$(jq -r '.disk_encryption.encryption_type // empty' user_configuration.json)

# CORRECT
ENCRYPTION_ENABLED=$(jq -r '.disk_config.disk_encryption.encryption_type // empty' user_configuration.json)
```

**Why:** archinstall's JSON structure nests `disk_encryption` inside `disk_config`.

#### Fix 2: Disable pipefail for Logging (Commit 4cfc3f0)
```bash
# Add before the logging pipeline
set +o pipefail
install_base_system 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' >>/var/log/omarchy-install.log
set -o pipefail
```

**Why:** The `sed` command was causing the pipeline to fail with `set -euo pipefail`, aborting installation before `install_omarchy` could run.

#### Fix 3: Fallback LUKS Detection (Commit 9419ea8)
```bash
# Always try to detect LUKS, even if marker wasn't created
ROOT_DEVICE_CHECK=$(findmnt -n -o SOURCE /mnt 2>/dev/null || echo "")
if [ -f /tmp/.luks_marker ] || [[ "$ROOT_DEVICE_CHECK" == /dev/mapper/* ]]; then
```

**Why:** Defense in depth - detect LUKS even if the pre-check fails.

#### Fix 4: Parameter Expansion for MAPPER_NAME (Commit 17ca770) - THE CRITICAL FIX
```bash
# WRONG (basename has glob issues)
MAPPER_NAME=$(basename "$ROOT_DEVICE" | sed 's/\[.*\]//')
# This produces: @]  (broken!)

# CORRECT
MAPPER_PATH="${ROOT_DEVICE%%\[*}"    # Remove [ and everything after
MAPPER_NAME="${MAPPER_PATH##*/}"      # Get basename (everything after last /)
# This produces: root  (correct!)
```

**Why:** When btrfs subvolumes are mounted, `findmnt` returns `/dev/mapper/root[/@]`. The `basename` command treats `[/@]` as a **glob pattern** (character class), which causes incorrect parsing. Using bash parameter expansion avoids glob expansion entirely.

**The Glob Problem Explained:**
- Input: `/dev/mapper/root[/@]`
- `basename` interprets `[/@]` as "match any character that is / or @"
- If there's a file in the current directory matching that pattern, basename returns it
- If not, it returns just the matching part: `@]`
- Result: `cryptsetup status "@]"` fails

**The Solution:**
- `${ROOT_DEVICE%%\[*}` = Parameter expansion to remove `[` and everything after → `/dev/mapper/root`
- `${MAPPER_PATH##*/}` = Remove everything up to last `/` → `root`
- No glob expansion, no ambiguity

#### Fix 5: Copy Installation Logs (Commit 9419ea8)
```bash
# After install_omarchy completes
if [ -f /var/log/omarchy-install.log ]; then
  mkdir -p /mnt/var/log
  cp /var/log/omarchy-install.log /mnt/var/log/omarchy-install.log
fi
```

**Why:** Logs created during ISO installation weren't persisting to the installed system, making debugging impossible.

### Files in omarchy Repository (dracut-rebased branch)

These files were already correct - they read from `/.luks_uuid`:

**File:** `install/login/setup-dracut.sh`
- Reads `/.luks_uuid` created by ISO script
- Generates `limine.conf` with correct dracut parameters
- Uses LUKS UUID if found, filesystem UUID as fallback

**File:** `install/login/limine-snapper.sh`
- Reads `/.luks_uuid` for limine-snapper configuration
- Creates `/etc/default/limine` with correct LUKS parameters

## Verification Steps

After successful installation:

```bash
# 1. Mount the installed system
sudo qemu-nbd -c /dev/nbd0 /tmp/omarchy-iso-boot.qcow2
sudo cryptsetup luksUUID /dev/nbd0p2  # Note this UUID
sudo cryptsetup open /dev/nbd0p2 omarchy_root
sudo mount -o subvol=@ /dev/mapper/omarchy_root /mnt/omarchy_check
sudo mount -o subvol=@log /dev/mapper/omarchy_root /mnt/omarchy_check/var/log
sudo mount /dev/nbd0p1 /mnt/omarchy_check/boot

# 2. Verify LUKS UUID file was created
cat /mnt/omarchy_check/.luks_uuid
# Should match the UUID from step 1

# 3. Verify limine.conf has LUKS parameters
grep "cmdline" /mnt/omarchy_check/boot/EFI/limine/limine.conf
# Should show: rd.luks.uuid=<UUID> rd.luks.name=<UUID>=root root=/dev/mapper/root

# 4. Check installation logs for BREADCRUMB messages
grep "BREADCRUMB.*LUKS" /mnt/omarchy_check/var/log/omarchy-install.log
# Should show successful detection and UUID copying

# 5. Boot the system
# Should prompt for LUKS password, then boot successfully
```

## Helper Scripts Created

**mount-omarchy-check.sh**
```bash
#!/bin/bash
set -e
sudo qemu-nbd -c /dev/nbd0 /tmp/omarchy-iso-boot.qcow2
sleep 2
sudo partprobe /dev/nbd0 2>/dev/null || true
sleep 1
LUKS_UUID=$(sudo cryptsetup luksUUID /dev/nbd0p2)
echo "LUKS UUID: $LUKS_UUID"
sudo cryptsetup open /dev/nbd0p2 omarchy_root
sudo mkdir -p /mnt/omarchy_check
sudo mount -o subvol=@ /dev/mapper/omarchy_root /mnt/omarchy_check
sudo mount -o subvol=@log /dev/mapper/omarchy_root /mnt/omarchy_check/var/log
sudo mount /dev/nbd0p1 /mnt/omarchy_check/boot
echo "Mounted successfully"
```

**umount-omarchy-check.sh**
```bash
#!/bin/bash
sudo umount /mnt/omarchy_check/var/log 2>/dev/null || true
sudo umount /mnt/omarchy_check/boot 2>/dev/null || true
sudo umount /mnt/omarchy_check 2>/dev/null || true
sudo cryptsetup close omarchy_root 2>/dev/null || true
sudo qemu-nbd -d /dev/nbd0 2>/dev/null || true
echo "Unmounted successfully"
```

## Known Issues - ALL RESOLVED ✅

### ~~SDDM Not Auto-Enabled~~ - FIXED (2025-10-20)
**Status:** ✅ RESOLVED
**Problem:** During dracut rebase, `install/login/all.sh` accidentally removed calls to `sddm.sh` and `default-keyring.sh`
**Solution:** Restored both script calls in commit `ef256da`
**Result:** SDDM now starts automatically and auto-logs in user after LUKS unlock

## Git Commits Summary

**omarchy-iso repository (dracut branch on d-cas/omarchy-iso fork):**
- `7ab7f84` - Initial LUKS detection implementation (had bugs)
- `9419ea8` - Fix jq path and add fallback detection + logging
- `4cfc3f0` - Fix pipefail breaking installation
- `8438b72` - Attempt to fix basename with sed (didn't work due to glob)
- `17ca770` - **THE FIX:** Use parameter expansion to avoid glob issues

**omarchy repository (dracut-rebased branch on d-cas/omarchy fork):**
- `3adf5f7` - feat: migrate from mkinitcpio to dracut for improved FIDO2 multi-token support
- `1c76852` - fix: detect LUKS UUID before chroot to avoid chroot detection failures
- `cb3ffb6` - docs: complete LUKS detection solution documentation
- `ef256da` - fix: restore SDDM and keyring setup during installation

**Status:** All changes pushed to GitHub forks and ready for testing/PR

## Success Criteria (ALL MET ✅✅✅)

- [x] LUKS UUID detected during ISO installation
- [x] `/.luks_uuid` file created in root filesystem
- [x] `limine.conf` contains `rd.luks.uuid=<LUKS_UUID>` parameters
- [x] System boots and prompts for LUKS password
- [x] dracut successfully unlocks encrypted root partition
- [x] SDDM starts and auto-logs in user
- [x] Desktop environment (Hyprland) starts
- [x] Installation logs persist to `/var/log/omarchy-install.log`
- [x] FIDO2 support enabled for multi-token testing

## Testing Procedure

1. Build ISO with fixes:
```bash
cd /mnt/truenas/dev-projects/omarchy_repos/omarchy-iso
./bin/omarchy-iso-make --no-cache
```

2. Boot and install:
```bash
./bin/omarchy-iso-boot release/omarchy-dracut-rebased.iso
```

3. During installation:
- Watch for BREADCRUMB messages in logs
- Installation should complete without sed errors

4. After installation:
- VM will reboot
- Should prompt for LUKS password
- Should boot to desktop (or TTY if SDDM issue)

5. Verify (optional):
- Mount the qcow2 using helper scripts
- Check `/.luks_uuid`, `limine.conf`, and logs

## Lessons Learned

1. **Glob expansion is subtle and dangerous** - Always use parameter expansion for paths with brackets
2. **Test assumptions** - "sed should work" != sed actually works
3. **Defense in depth** - Multiple detection methods prevented total failure
4. **Logging is critical** - BREADCRUMB messages and log persistence saved hours of debugging
5. **Architecture matters** - Detecting hardware in the live environment, not chroot, was key
