# Omarchy LUKS + dracut Implementation Guide

**Status:** ✅ FULLY WORKING (tested 2025-10-20)
**Last Updated:** 2025-10-20

## Overview

This document explains how Omarchy detects and configures LUKS-encrypted installations to work with dracut initramfs instead of mkinitcpio.

**Current Status:** Complete implementation with LUKS detection, SDDM autologin, and FIDO2 support all working.

## Problem Statement

**Challenge:** archinstall (the base installer) generates a `limine.conf` bootloader configuration that uses mkinitcpio-style parameters:
```
cryptdevice=UUID=<filesystem-uuid>:root
```

**Issue:** dracut doesn't understand mkinitcpio syntax. It needs:
```
rd.luks.uuid=<LUKS-device-uuid> rd.luks.name=<LUKS-device-uuid>=root
```

**Critical difference:**
- mkinitcpio uses the **filesystem UUID** (from the decrypted partition)
- dracut needs the **LUKS container UUID** (from the encrypted device itself)

## Solution Architecture

### Two-Repository Approach

1. **omarchy-iso** - Detects LUKS during installation (live environment)
2. **omarchy** - Reads detection results and configures bootloader (chroot environment)

### Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│ ISO ENVIRONMENT (omarchy-iso repo)                          │
│ File: configs/airootfs/root/.automated_script.sh            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ 1. User runs configurator → creates user_configuration.json │
│                                                              │
│ 2. PRE-ARCHINSTALL DETECTION                                │
│    ├─ Check .disk_config.disk_encryption.encryption_type    │
│    ├─ If "luks" → create /tmp/.luks_marker                  │
│    └─ Store target disk info                                │
│                                                              │
│ 3. archinstall runs                                         │
│    ├─ Creates encrypted partitions                          │
│    ├─ Sets up LUKS                                          │
│    ├─ Mounts /dev/mapper/root[/@] at /mnt                   │
│    └─ Generates broken limine.conf                          │
│                                                              │
│ 4. POST-ARCHINSTALL DETECTION                               │
│    ├─ Check if /mnt is on /dev/mapper device               │
│    ├─ Extract mapper name from /dev/mapper/root[/@]        │
│    │  └─ Use ${var%%\[*} to strip [/@] (glob-safe!)        │
│    ├─ Run: cryptsetup status root                          │
│    ├─ Get LUKS device from cryptsetup output               │
│    ├─ Run: cryptsetup luksUUID <device>                    │
│    ├─ Write UUID to /mnt/.luks_uuid                        │
│    └─ BREADCRUMB logging to /var/log/omarchy-install.log   │
│                                                              │
│ 5. Copy logs to /mnt/var/log/omarchy-install.log           │
│                                                              │
│ 6. Chroot and run install.sh                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ↓
┌─────────────────────────────────────────────────────────────┐
│ CHROOT ENVIRONMENT (omarchy repo)                           │
│ Files: install/login/setup-dracut.sh                        │
│        install/login/limine-snapper.sh                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ 7. setup-dracut.sh runs                                     │
│    ├─ Reads /.luks_uuid (if exists)                        │
│    ├─ Builds dracut cmdline:                               │
│    │  rd.luks.uuid=<UUID>                                  │
│    │  rd.luks.name=<UUID>=root                             │
│    │  root=/dev/mapper/root                                │
│    ├─ OVERWRITES limine.conf (hostile takeover!)           │
│    └─ Generates dracut initramfs images                    │
│                                                              │
│ 8. limine-snapper.sh runs                                  │
│    ├─ Reads /.luks_uuid (if exists)                        │
│    └─ Configures /etc/default/limine                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ↓
                         System Boots
                              │
                              ↓
┌─────────────────────────────────────────────────────────────┐
│ BOOT SEQUENCE                                                │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ 1. Limine reads /boot/EFI/limine/limine.conf               │
│ 2. Kernel boots with rd.luks.uuid parameter                │
│ 3. dracut initramfs starts                                  │
│ 4. dracut prompts for LUKS password                        │
│ 5. dracut unlocks /dev/mapper/root                         │
│ 6. dracut mounts root filesystem                           │
│ 7. System continues boot process                           │
│ 8. SDDM starts (if enabled) → Desktop                      │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Details

### Part 1: ISO Detection (omarchy-iso)

**File:** `configs/airootfs/root/.automated_script.sh`

**Location in flow:** Lines 132-214 (after archinstall patching, before archinstall runs)

#### Pre-archinstall Detection

```bash
# Look for LUKS devices by checking user_configuration.json
LUKS_UUID=""
if [ -f "user_configuration.json" ]; then
  # Check if encryption is enabled in the config
  # NOTE: Must use .disk_config.disk_encryption, not just .disk_encryption!
  ENCRYPTION_ENABLED=$(jq -r '.disk_config.disk_encryption.encryption_type // empty' \
    user_configuration.json 2>/dev/null || echo "")

  if [ -n "$ENCRYPTION_ENABLED" ] && [ "$ENCRYPTION_ENABLED" != "null" ]; then
    echo "BREADCRUMB: Disk encryption detected in configuration" >&2

    # Create marker file for post-archinstall detection
    echo "encryption_enabled" > /tmp/.luks_marker
    echo "BREADCRUMB: Created encryption marker in /tmp/.luks_marker" >&2
  else
    echo "BREADCRUMB: No disk encryption configured" >&2
  fi
fi
```

**Why this works:**
- Runs BEFORE archinstall, so we know encryption is intended
- Creates a marker file that survives through archinstall execution
- BREADCRUMB messages go to stderr, captured in log

#### Post-archinstall Detection

```bash
# POST-ARCHINSTALL LUKS DETECTION
echo "BREADCRUMB: Post-archinstall LUKS detection starting..." >&2

# Always try to detect LUKS, even if marker wasn't created (defense in depth)
ROOT_DEVICE_CHECK=$(findmnt -n -o SOURCE /mnt 2>/dev/null || echo "")

if [ -f /tmp/.luks_marker ] || [[ "$ROOT_DEVICE_CHECK" == /dev/mapper/* ]]; then
  echo "BREADCRUMB: Encryption detected (marker or /dev/mapper device), detecting LUKS UUID..." >&2

  # Find the encrypted root device that archinstall just created
  ROOT_DEVICE=$(findmnt -n -o SOURCE /mnt 2>/dev/null || echo "")
  echo "BREADCRUMB: Root device mounted at /mnt: ${ROOT_DEVICE}" >&2

  if [[ "$ROOT_DEVICE" == /dev/mapper/* ]]; then
    # This is a mapped device, find its backing LUKS device

    # CRITICAL: Strip btrfs subvolume notation (e.g., /dev/mapper/root[/@] -> root)
    # Must use parameter expansion to avoid glob issues with basename!
    MAPPER_PATH="${ROOT_DEVICE%%\[*}"    # Remove [ and everything after
    MAPPER_NAME="${MAPPER_PATH##*/}"      # Get basename (everything after last /)

    LUKS_DEVICE=$(cryptsetup status "$MAPPER_NAME" 2>/dev/null | grep "device:" | awk '{print $2}')
    echo "BREADCRUMB: LUKS backing device: ${LUKS_DEVICE}" >&2

    if [ -n "$LUKS_DEVICE" ]; then
      LUKS_UUID=$(cryptsetup luksUUID "$LUKS_DEVICE" 2>/dev/null || echo "")

      if [ -n "$LUKS_UUID" ]; then
        echo "$LUKS_UUID" > /tmp/.luks_uuid
        echo "BREADCRUMB: ✓ LUKS UUID detected and saved: ${LUKS_UUID}" >&2

        # Copy to /mnt so it's available in chroot
        cp /tmp/.luks_uuid /mnt/.luks_uuid
        echo "BREADCRUMB: ✓ Copied LUKS UUID to /mnt/.luks_uuid for chroot access" >&2
      else
        echo "BREADCRUMB: WARNING - Failed to get LUKS UUID from ${LUKS_DEVICE}" >&2
      fi
    else
      echo "BREADCRUMB: WARNING - Failed to find LUKS backing device for ${MAPPER_NAME}" >&2
    fi
  else
    echo "BREADCRUMB: Root device is not encrypted (not /dev/mapper/*)" >&2
  fi

  rm /tmp/.luks_marker
else
  echo "BREADCRUMB: No encryption marker found, skipping LUKS detection" >&2
fi
```

**Critical gotchas:**

1. **Glob expansion with basename**
   ```bash
   # WRONG - basename interprets [/@] as a glob pattern!
   MAPPER_NAME=$(basename "$ROOT_DEVICE")  # Returns: @]

   # CORRECT - use parameter expansion
   MAPPER_PATH="${ROOT_DEVICE%%\[*}"       # Returns: /dev/mapper/root
   MAPPER_NAME="${MAPPER_PATH##*/}"         # Returns: root
   ```

2. **btrfs subvolume notation**
   - `findmnt` returns: `/dev/mapper/root[/@]`
   - The `[/@]` suffix indicates the subvolume
   - Must be stripped before calling `cryptsetup status`

3. **Defense in depth**
   - Check both marker file AND actual /dev/mapper detection
   - Prevents failure if pre-detection doesn't run

#### Log Persistence

```bash
# After install_omarchy completes (end of script)
if [ -f /var/log/omarchy-install.log ]; then
  mkdir -p /mnt/var/log
  cp /var/log/omarchy-install.log /mnt/var/log/omarchy-install.log
  echo "Installation log copied to /mnt/var/log/omarchy-install.log"
fi
```

**Why this matters:**
- Logs are created in the ISO's `/var/log/`
- They disappear when the ISO environment ends
- Copying to `/mnt/var/log/` persists them to the installed system
- Critical for post-installation debugging

### Part 2: Bootloader Configuration (omarchy)

**File:** `install/login/setup-dracut.sh`

**Location in flow:** Runs during `install.sh` execution in chroot

#### Reading LUKS UUID

```bash
# Check if LUKS UUID was detected by the ISO installer (pre-chroot)
luks_detected=false
if [ -f "/.luks_uuid" ]; then
  luks_uuid=$(cat /.luks_uuid 2>/dev/null | tr -d '[:space:]')
  luks_dev=$(cat /.luks_device 2>/dev/null | tr -d '[:space:]')
  echo "BREADCRUMB: Found pre-detected LUKS info:"
  echo "BREADCRUMB:   UUID: $luks_uuid"
  echo "BREADCRUMB:   Device: $luks_dev"
else
  echo "BREADCRUMB: No /.luks_uuid file found - assuming unencrypted installation"
fi
```

#### Generating dracut-compatible cmdline

```bash
# Build cmdline based on LUKS detection
if [ -n "$luks_uuid" ]; then
  echo "BREADCRUMB: *** ENCRYPTED ROOT PATH ***"

  # Get root filesystem info for additional parameters
  root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null)
  root_opts=""
  echo "BREADCRUMB: Root fstype: $root_fstype"

  if [ "$root_fstype" = "btrfs" ]; then
    root_subvol=$(findmnt -n -o OPTIONS / 2>/dev/null | grep -oP 'subvol=\K[^,]+' || echo "@")
    root_opts="rootflags=subvol=$root_subvol rootfstype=btrfs"
    echo "BREADCRUMB: Btrfs subvol: $root_subvol"
  fi

  # Build dracut-compatible cmdline with LUKS parameters
  cmdline="rd.luks.uuid=$luks_uuid rd.luks.name=${luks_uuid}=root root=/dev/mapper/root $root_opts rw"
  echo "BREADCRUMB: Generated LUKS cmdline: $cmdline"
else
  # Unencrypted fallback
  root_uuid=$(findmnt -n -o UUID /)
  echo "BREADCRUMB: ✗ UNENCRYPTED ROOT FALLBACK - Using filesystem UUID"
  cmdline="root=UUID=$root_uuid rw quiet splash"
fi
```

#### Hostile Takeover of limine.conf

```bash
echo "BREADCRUMB: Performing HOSTILE TAKEOVER of /boot/limine.conf..."
echo "BREADCRUMB: This OVERWRITES any existing config from archinstall"

# Get kernel version
kernel_version=$(ls /boot/vmlinuz-* 2>/dev/null | head -1 | sed 's/.*vmlinuz-//')

# COMPLETELY OVERWRITE limine.conf (no -a flag)
sudo tee /boot/limine.conf <<EOF >/dev/null
### Read more at config document: https://github.com/limine-bootloader/limine/blob/trunk/CONFIG.md
#timeout: 3
default_entry: 2
interface_branding: Omarchy Bootloader
interface_branding_color: 2
hash_mismatch_panic: no

term_background: 1a1b26
backdrop: 1a1b26

# Terminal colors (Tokyo Night palette)
term_palette: 15161e;f7768e;9ece6a;e0af68;7aa2f7;bb9af7;7dcfff;a9b1d6
term_palette_bright: 414868;f7768e;9ece6a;e0af68;7aa2f7;bb9af7;7dcfff;c0caf5

# Text colors
term_foreground: c0caf5
term_foreground_bright: c0caf5
term_background_bright: 24283b

# Omarchy Boot Entry (dracut-compatible)
/Omarchy
  protocol: linux
  kernel_path: boot():/vmlinuz-${kernel_version}
  module_path: boot():/initramfs-${kernel_version}.img
  cmdline: ${cmdline}
EOF

echo "BREADCRUMB: ✓ limine.conf OVERWRITTEN successfully"
```

**Why "hostile takeover":**
- archinstall creates `limine.conf` first
- It uses mkinitcpio-style parameters
- We can't merge or patch - must completely replace
- This happens AFTER archinstall, so it's safe

## Debugging Guide

### Checking if LUKS Detection Worked

1. **Mount the installed system:**
   ```bash
   sudo qemu-nbd -c /dev/nbd0 /tmp/omarchy-iso-boot.qcow2
   sudo cryptsetup open /dev/nbd0p2 omarchy_root
   sudo mount -o subvol=@ /dev/mapper/omarchy_root /mnt/omarchy_check
   sudo mount -o subvol=@log /dev/mapper/omarchy_root /mnt/omarchy_check/var/log
   sudo mount /dev/nbd0p1 /mnt/omarchy_check/boot
   ```

2. **Check the UUID file:**
   ```bash
   cat /mnt/omarchy_check/.luks_uuid
   ```
   Should contain a UUID like: `9b772541-f413-46a2-8680-3a501cdb7492`

3. **Verify it matches the actual LUKS UUID:**
   ```bash
   sudo cryptsetup luksUUID /dev/nbd0p2
   ```

4. **Check limine.conf:**
   ```bash
   grep "cmdline" /mnt/omarchy_check/boot/EFI/limine/limine.conf
   ```
   Should show: `rd.luks.uuid=<UUID> rd.luks.name=<UUID>=root root=/dev/mapper/root`

   Should NOT show: `root=UUID=<filesystem-uuid>` or `cryptdevice=`

5. **Check installation logs:**
   ```bash
   grep "BREADCRUMB" /mnt/omarchy_check/var/log/omarchy-install.log | grep LUKS
   ```
   Look for:
   - "✓ LUKS UUID detected and saved"
   - "✓ Copied LUKS UUID to /mnt/.luks_uuid"
   - "*** ENCRYPTED ROOT PATH ***"

### Common Issues

#### Issue: `/.luks_uuid` doesn't exist

**Symptoms:**
- File not found when checking
- limine.conf has `root=UUID=<filesystem-uuid>`
- Boot hangs waiting for device

**Causes:**
1. Pre-archinstall detection failed (wrong JSON path)
2. Post-archinstall detection failed (basename glob issue)
3. Logs not showing BREADCRUMB messages

**Diagnosis:**
```bash
# Check what BREADCRUMB messages are in the log
grep "BREADCRUMB.*Post-archinstall" /mnt/omarchy_check/var/log/omarchy-install.log
grep "BREADCRUMB.*backing device" /mnt/omarchy_check/var/log/omarchy-install.log
```

**Fix:**
- Verify JSON path: `.disk_config.disk_encryption.encryption_type`
- Verify parameter expansion for MAPPER_NAME (not basename)
- Check that logs are being copied

#### Issue: Boot hangs at "A start job is running for dracut initqueue"

**Symptoms:**
- System prompts for LUKS password
- After entering password, hangs
- Or: doesn't prompt, just hangs

**Causes:**
1. Wrong UUID in limine.conf (filesystem UUID instead of LUKS UUID)
2. dracut can't find the LUKS device
3. Missing rd.luks.name parameter

**Diagnosis:**
```bash
# Compare the UUIDs
sudo cryptsetup luksUUID /dev/nbd0p2  # LUKS UUID
grep cmdline /mnt/omarchy_check/boot/EFI/limine/limine.conf  # Should match
```

**Fix:**
- Ensure `/.luks_uuid` contains the LUKS device UUID (not filesystem UUID)
- Verify `setup-dracut.sh` read the file correctly
- Check BREADCRUMB messages for "*** ENCRYPTED ROOT PATH ***"

#### Issue: SDDM doesn't start, boots to TTY

**Symptoms:**
- System boots successfully
- LUKS unlocks correctly
- Shows text login instead of graphical login

**Cause:**
- SDDM not enabled in systemd

**Fix:**
```bash
# After logging in
sudo systemctl enable sddm
sudo systemctl start sddm
```

**Permanent fix needed:**
Add to `install/login/all.sh` or equivalent:
```bash
if [ -n "$DISPLAY_MANAGER" ]; then
  systemctl enable "$DISPLAY_MANAGER"
fi
```

## Testing Checklist

- [ ] Build ISO with `--no-cache` flag
- [ ] Boot ISO and run installer
- [ ] Enable disk encryption during installation
- [ ] Watch for BREADCRUMB messages in output
- [ ] Installation completes without errors
- [ ] System reboots
- [ ] LUKS password prompt appears
- [ ] After password, system continues booting
- [ ] Desktop environment starts (or TTY login)
- [ ] Mount and verify `/.luks_uuid` exists
- [ ] Verify `limine.conf` has dracut parameters
- [ ] Check installation logs for BREADCRUMB success messages

## Files Reference

### omarchy-iso repository (main branch)
- `configs/airootfs/root/.automated_script.sh` - LUKS detection logic

### omarchy repository (dracut-rebased branch)
- `install/login/setup-dracut.sh` - dracut + limine configuration
- `install/login/limine-snapper.sh` - limine-snapper integration
- `install/login/all.sh` - Calls all login scripts

### Helper Scripts (created during debugging)
- `/tmp/mount-omarchy-check.sh` - Mount qcow2 for inspection
- `/tmp/umount-omarchy-check.sh` - Clean unmount

## Future Improvements

1. **SDDM auto-enable** - Add systemctl enable to installer
2. **Better error messages** - If LUKS detection fails, show clear error
3. **Validation** - Verify UUID is valid before writing to file
4. **Fallback handling** - If /.luks_uuid is missing, try in-chroot detection
5. **Documentation in-system** - Include this guide in installed system

## References

- [dracut documentation](https://man.archlinux.org/man/dracut.cmdline.7)
- [Limine bootloader config](https://github.com/limine-bootloader/limine/blob/trunk/CONFIG.md)
- [LUKS2 specification](https://gitlab.com/cryptsetup/cryptsetup/-/wikis/home)
- [archinstall documentation](https://archinstall.archlinux.page/)
