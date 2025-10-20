# Omarchy Dracut LUKS Detection - Troubleshooting Workflow

**Status:** ✅ PROBLEM SOLVED (2025-10-19)

**Current state:** LUKS detection working, system boots correctly. See CRITICAL-FINDINGS.md and LUKS-DRACUT-IMPLEMENTATION.md for complete solution.

**This document:** Kept for reference and debugging future issues.

---

## Quick Mount/Unmount Helper Scripts

For faster debugging, use these helper scripts created during troubleshooting:

**To mount:**
```bash
/tmp/mount-omarchy-check.sh
```

**To unmount:**
```bash
/tmp/umount-omarchy-check.sh
```

See LUKS-DRACUT-IMPLEMENTATION.md for the full script source code.

---

## Prerequisites

Make sure the VM is shut down before starting:
```bash
# Check for running QEMU processes
ps aux | grep qemu | grep -v grep

# If any found, kill them
killall qemu-system-x86_64
```

---

## Section 1: Quick Diagnosis - Check Final Boot Config

**What we're checking:** Does limine.conf have the correct LUKS UUID or wrong filesystem UUID?

### Step 1.1: Mount the qcow2 Image

**QUICK WAY (using helper script):**
```bash
/tmp/mount-omarchy-check.sh
```

**MANUAL WAY (if helper doesn't exist):**
```bash
# Load NBD kernel module
sudo modprobe nbd max_part=8

# Connect qcow2 as network block device
sudo qemu-nbd --connect=/dev/nbd0 /tmp/omarchy-iso-boot.qcow2

# Wait a moment for device to be ready
sleep 2

# Check partitions
sudo fdisk -l /dev/nbd0
```

**Expected output:**
```
Device        Start      End  Sectors Size Type
/dev/nbd0p1    2048  4196351  4194304   2G EFI System
/dev/nbd0p2 4196352 41940991 37744640  18G Linux root (x86-64)
```

✅ **Success:** Two partitions (EFI + Linux root)
❌ **Failure:** No partitions or different layout → installation may have failed

---

### Step 1.2: Get the CORRECT LUKS UUID
```bash
# This is what SHOULD be in limine.conf
sudo cryptsetup luksUUID /dev/nbd0p2
```

**Expected output:**
```
68ba123d-e341-4a7f-8677-0c8903ab1a2a
```

**📝 Write this down!** This is the LUKS container UUID that dracut needs.

---

### Step 1.3: Unlock and Mount the System
```bash
# Unlock LUKS partition (you'll need to enter password)
sudo cryptsetup open /dev/nbd0p2 omarchy_root

# Create mount point
sudo mkdir -p /mnt/omarchy_check

# Mount root subvolume (btrfs)
sudo mount -o subvol=@ /dev/mapper/omarchy_root /mnt/omarchy_check

# Mount boot partition
sudo mount /dev/nbd0p1 /mnt/omarchy_check/boot
```

✅ **Success:** All mounts complete without errors
❌ **Failure:** "mount point does not exist" → check if you used `subvol=@`

---

### Step 1.4: Check limine.conf
```bash
# Check which config file exists
ls -la /mnt/omarchy_check/boot/EFI/BOOT/limine.conf 2>/dev/null && \
  echo "Found: /boot/EFI/BOOT/limine.conf" || \
  echo "Not found: /boot/EFI/BOOT/limine.conf"

ls -la /mnt/omarchy_check/boot/EFI/limine/limine.conf 2>/dev/null && \
  echo "Found: /boot/EFI/limine/limine.conf" || \
  echo "Not found: /boot/EFI/limine/limine.conf"

# Read the config (adjust path based on above)
cat /mnt/omarchy_check/boot/EFI/limine/limine.conf
```

**Look for the `cmdline:` section:**

**✅ CORRECT (LUKS UUID):**
```
cmdline: rd.luks.uuid=68ba123d-e341-4a7f-8677-0c8903ab1a2a rd.luks.name=68ba123d-e341-4a7f-8677-0c8903ab1a2a=root root=/dev/mapper/root rw
```

**❌ WRONG (Filesystem UUID):**
```
cmdline: root=UUID=a023dd39-bd3e-47d8-82bc-1428986ddf08 rw
```

**What it means:**
- ✅ Correct → Our fix worked! Issue is elsewhere (maybe initramfs, check Section 6)
- ❌ Wrong → Fix didn't run. Continue to Section 2 to find out why.

---

### Step 1.5: Quick Check - Get Filesystem UUID for Comparison
```bash
# Get the WRONG UUID (filesystem UUID)
sudo blkid /dev/mapper/omarchy_root | grep -o 'UUID="[^"]*"'
```

**Expected:**
```
UUID="a023dd39-bd3e-47d8-82bc-1428986ddf08"
```

If this UUID appears in `cmdline:` instead of the LUKS UUID → **Fix failed**

---

## Section 2: Pre-Chroot Detection Check

**What we're checking:** Did detect-luks.sh run and create the /.luks_uuid file?

### Step 2.1: Check for .luks_uuid File
```bash
# Check if file exists
ls -la /mnt/omarchy_check/.luks_uuid 2>/dev/null && echo "✅ File exists" || echo "❌ File not found"

# Check if file has content
cat /mnt/omarchy_check/.luks_uuid 2>/dev/null && echo "" || echo "❌ File empty or doesn't exist"
```

**✅ Success:**
```
✅ File exists
68ba123d-e341-4a7f-8677-0c8903ab1a2a
```

**❌ Failure scenarios:**

| Symptom | Meaning | Next Step |
|---------|---------|-----------|
| File not found | detect-luks.sh didn't run | Check Section 3 |
| File exists but empty | Script ran but detection failed | Check Section 3 for logs |
| File has wrong UUID | Script detected wrong device | Check Section 3 for logs |

---

### Step 2.2: Check .luks_device File
```bash
cat /mnt/omarchy_check/.luks_device 2>/dev/null
```

**Expected:**
```
/dev/vda2
```
(or /dev/sda2, /dev/nvme0n1p2 depending on VM disk type)

---

## Section 3: Installation Log Analysis

**What we're checking:** Did detect-luks.sh run during installation? What did it find?

### Step 3.1: Check for Installation Logs
```bash
# Look for any installation logs
sudo find /mnt/omarchy_check/var/log -name "*install*" -o -name "*omarchy*" 2>/dev/null

# Check systemd journal if available
sudo ls -la /mnt/omarchy_check/var/log/journal/ 2>/dev/null
```

**Note:** Installation logs might not persist. If no logs found, check ISO build.

---

### Step 3.2: Check if detect-luks.sh Was Included in ISO

**From your host system (not inside mounted chroot):**

```bash
# Check the ISO that was used for installation
iso_file="/home/dcas/truenas/dev-projects/omarchy_repos/omarchy-iso/release/omarchy-dracut-rebased.iso"

# Mount the ISO temporarily
sudo mkdir -p /mnt/iso_check
sudo mount -o loop "$iso_file" /mnt/iso_check

# Check if detect-luks.sh exists in the ISO
ls -la /mnt/iso_check/arch/x86_64/airootfs.sfs 2>/dev/null || \
ls -la /mnt/iso_check/arch/omarchy*/airootfs.sfs 2>/dev/null

# Unmount
sudo umount /mnt/iso_check
```

**Alternative: Check Git Commit in ISO**

The ISO should have been built from commit `1c76852` which includes detect-luks.sh.

---

## Section 4: Script Execution Check

**What we're checking:** Did setup-dracut.sh and limine-snapper.sh run? Did they read the file?

### Step 4.1: Check if Scripts Exist in Installed System
```bash
# These might have been cleaned up after installation
# But check if omarchy directory persists
sudo ls -la /mnt/omarchy_check/root/omarchy/install/preflight/ 2>/dev/null
sudo ls -la /mnt/omarchy_check/root/omarchy/install/login/ 2>/dev/null
```

**Expected:** Directory not found (cleaned up after install)

**If found:** Installation might have failed partway through

---

### Step 4.2: Check /etc/default/limine
```bash
# This file is created by limine-snapper.sh
cat /mnt/omarchy_check/etc/default/limine
```

**Look for:**
```bash
KERNEL_CMDLINE[default]="rd.luks.uuid=68ba123d-... rd.luks.name=...=root root=/dev/mapper/root rw"
```

**✅ Correct:** Contains LUKS UUID
**❌ Wrong:** Contains filesystem UUID or missing LUKS parameters

---

### Step 4.3: Check Dracut Configuration
```bash
# Check dracut configs were installed
ls -la /mnt/omarchy_check/etc/dracut.conf.d/
cat /mnt/omarchy_check/etc/dracut.conf.d/10-omarchy.conf
```

**Expected:**
```bash
add_dracutmodules+=" systemd systemd-initrd base kernel-modules "
add_dracutmodules+=" plymouth crypt systemd-cryptsetup "
```

---

## Section 5: Package Verification

**What we're checking:** Is dracut actually installed?

### Step 5.1: Check Installed Packages
```bash
# Check if dracut is installed
sudo ls /mnt/omarchy_check/var/lib/pacman/local/ | grep dracut

# Check if mkinitcpio is installed (for archinstall compatibility)
sudo ls /mnt/omarchy_check/var/lib/pacman/local/ | grep mkinitcpio

# Check limine-snapper-sync
sudo ls /mnt/omarchy_check/var/lib/pacman/local/ | grep limine-snapper-sync
```

**Expected:**
```
dracut-108-1
mkinitcpio-39.2-2
limine-snapper-sync-...
```

**❌ If dracut is missing:** ISO was built from wrong branch or package list wasn't updated

---

## Section 6: Initramfs Inspection

**What we're checking:** Did dracut generate the initramfs correctly?

### Step 6.1: Check Initramfs Files
```bash
# List all initramfs files
ls -lh /mnt/omarchy_check/boot/initramfs*
```

**Expected:**
```
-rwxr-xr-x 50M initramfs-6.17.3-arch2-1.img  # dracut-generated (larger)
-rwxr-xr-x 29M initramfs-linux.img           # possibly mkinitcpio (smaller)
```

**Note:** Dracut initramfs is typically larger (40-60MB) vs mkinitcpio (20-30MB)

---

### Step 6.2: Inspect Dracut Initramfs Contents
```bash
# Extract and check dracut initramfs
cd /tmp
sudo mkdir -p /tmp/initramfs_check
cd /tmp/initramfs_check

# Copy initramfs out
sudo cp /mnt/omarchy_check/boot/initramfs-6.17.3-arch2-1.img ./

# Extract it (dracut uses cpio + compression)
sudo /usr/lib/dracut/skipcpio initramfs-6.17.3-arch2-1.img | \
  zcat | sudo cpio -idmv 2>&1 | head -20

# Check for LUKS modules
ls -la usr/lib/dracut/hooks/cmdline/ 2>/dev/null | grep -i crypt
ls -la usr/lib/modules/*/kernel/drivers/md/ 2>/dev/null | grep dm-crypt
```

**✅ Success:** Contains cryptsetup, dm-crypt, systemd-cryptsetup modules
**❌ Failure:** Missing crypto modules → dracut config issue

---

### Step 6.3: Check Dracut Command Line
```bash
# Check what was embedded in the initramfs
sudo cat /tmp/initramfs_check/etc/cmdline.d/*.conf 2>/dev/null
```

**Expected:** Should contain `rd.luks.uuid=...` parameters

---

## Section 7: Common Failure Modes

### Failure Mode 1: /.luks_uuid File Not Found

**Symptoms:**
- File doesn't exist in installed system
- limine.conf has filesystem UUID

**Root causes:**
1. detect-luks.sh didn't run (not in preflight/all.sh)
2. detect-luks.sh failed to detect LUKS (check logs)
3. ISO was built before commit 1c76852

**How to verify:**
```bash
# Check if ISO includes detect-luks.sh
cd /home/dcas/truenas/dev-projects/omarchy_repos/omarchy
git log --oneline | grep "detect LUKS UUID before chroot"
# Should show: 1c76852 fix: detect LUKS UUID before chroot...

# Check ISO build date vs commit date
ls -l /home/dcas/truenas/dev-projects/omarchy_repos/omarchy-iso/release/*.iso
git log -1 --format="%ai" 1c76852
```

**Fix:** Rebuild ISO with `--no-cache`

---

### Failure Mode 2: File Exists But Has Wrong UUID

**Symptoms:**
- /.luks_uuid exists but contains filesystem UUID
- Or contains empty/garbled data

**Root cause:** detect-luks.sh detection logic failed

**How to verify:**
```bash
# Compare UUIDs
echo "LUKS UUID (correct):"
sudo cryptsetup luksUUID /dev/nbd0p2

echo "/.luks_uuid file contains:"
cat /mnt/omarchy_check/.luks_uuid

echo "Filesystem UUID (wrong):"
sudo blkid /dev/mapper/omarchy_root | grep -o 'UUID="[^"]*"'
```

**Fix:** Check detect-luks.sh logic, may need to add more detection methods

---

### Failure Mode 3: File Correct But limine.conf Wrong

**Symptoms:**
- /.luks_uuid has correct LUKS UUID
- limine.conf still has filesystem UUID

**Root cause:** setup-dracut.sh or limine-snapper.sh didn't read from file

**How to verify:**
```bash
# Check if scripts were updated to read from file
cd /home/dcas/truenas/dev-projects/omarchy_repos/omarchy
grep -n "/.luks_uuid" install/login/setup-dracut.sh
grep -n "/.luks_uuid" install/login/limine-snapper.sh
```

**Expected:** Both should show code reading from `/.luks_uuid`

**Fix:** Scripts might be old version, rebuild ISO

---

### Failure Mode 4: Everything Correct But Still Fails to Boot

**Symptoms:**
- /.luks_uuid has correct UUID
- limine.conf has correct `rd.luks.uuid=...`
- Still drops to dracut emergency shell

**Possible causes:**
1. Initramfs missing crypto modules
2. Wrong kernel command line syntax
3. Dracut not finding the device for other reasons

**How to verify:**
```bash
# Check exact boot parameters in limine.conf
grep "cmdline:" /mnt/omarchy_check/boot/EFI/limine/limine.conf

# Should have ALL of these:
# rd.luks.uuid=<UUID>
# rd.luks.name=<UUID>=root
# root=/dev/mapper/root
```

**Debug:** Boot with `rd.debug rd.shell` to get dracut debug shell

---

## Section 8: ISO Build Verification

**What we're checking:** Was the ISO built from the correct branch with latest code?

### Step 8.1: Check ISO Build Configuration
```bash
cd /home/dcas/truenas/dev-projects/omarchy_repos/omarchy-iso

# Check what branch is configured
grep "OMARCHY_INSTALLER_REF" bin/omarchy-iso-make
grep "OMARCHY_INSTALLER_REF" builder/build-iso.sh
```

**Expected both show:**
```bash
OMARCHY_INSTALLER_REF="${OMARCHY_INSTALLER_REF:-dracut-rebased}"
```

---

### Step 8.2: Verify Latest Code is Pushed to GitHub
```bash
cd /mnt/truenas/dev-projects/omarchy_repos/omarchy

# Check local commit
git log -1 --oneline

# Check remote commit
git log -1 --oneline origin/dracut-rebased

# They should match!
```

**Expected:**
```
1c76852 fix: detect LUKS UUID before chroot to avoid chroot detection failures
```

---

### Step 8.3: Check ISO Build Date
```bash
ls -lh /home/dcas/truenas/dev-projects/omarchy_repos/omarchy-iso/release/*.iso

# Should be recent (today's date)
```

---

## Section 9: Cleanup

**Always run after troubleshooting:**

```bash
# Unmount everything
sudo umount /mnt/omarchy_check/boot 2>/dev/null
sudo umount /mnt/omarchy_check 2>/dev/null
sudo rm -rf /mnt/omarchy_check

# Close LUKS
sudo cryptsetup close omarchy_root 2>/dev/null

# Disconnect NBD
sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null

# Clean up temp files
sudo rm -rf /tmp/initramfs_check 2>/dev/null

echo "✅ Cleanup complete"
```

---

## Quick Reference: Expected File States

| File/Config | Expected State | If Wrong |
|-------------|---------------|----------|
| `/.luks_uuid` | Contains LUKS UUID (68ba123d-...) | detect-luks.sh didn't run |
| `/.luks_device` | Contains device path (/dev/vda2) | detect-luks.sh didn't run |
| `/etc/default/limine` | KERNEL_CMDLINE has rd.luks.uuid= | limine-snapper.sh failed |
| `/boot/EFI/limine/limine.conf` | cmdline: rd.luks.uuid=... | setup-dracut.sh hostile takeover failed |
| `/boot/initramfs-*.img` | 40-60MB size | dracut generated correctly |
| `/etc/dracut.conf.d/10-omarchy.conf` | Exists with crypto modules | dracut config not installed |

---

## Decision Tree

```
Start: System drops to dracut emergency shell
│
├─ Check limine.conf cmdline
│  │
│  ├─ Has rd.luks.uuid=<LUKS_UUID>? → ✅ Boot config correct
│  │                                   └─ Check Section 6 (initramfs)
│  │
│  └─ Has root=UUID=<FS_UUID>? → ❌ Boot config wrong
│                                 └─ Check /.luks_uuid file
│                                    │
│                                    ├─ File exists with correct UUID?
│                                    │  └─ setup-dracut.sh didn't run/failed
│                                    │     Check Section 4
│                                    │
│                                    └─ File missing or wrong?
│                                       └─ detect-luks.sh didn't run/failed
│                                          Check Section 3
│                                          Rebuild ISO with --no-cache
```

---

## Emergency: Force Manual Fix

If you need to test immediately and can't wait for ISO rebuild:

```bash
# 1. Mount system (Steps 1.1-1.3 above)

# 2. Get LUKS UUID
LUKS_UUID=$(sudo cryptsetup luksUUID /dev/nbd0p2)
echo "LUKS UUID: $LUKS_UUID"

# 3. Manually fix limine.conf
sudo tee /mnt/omarchy_check/boot/EFI/limine/limine.conf <<EOF
#timeout: 3
default_entry: 1
interface_branding: Omarchy Bootloader

/Omarchy
  protocol: linux
  kernel_path: boot():/vmlinuz-linux
  module_path: boot():/initramfs-linux.img
  cmdline: rd.luks.uuid=$LUKS_UUID rd.luks.name=${LUKS_UUID}=root root=/dev/mapper/root rw
EOF

# 4. Cleanup (Section 9)

# 5. Boot and test
```

This proves whether the fix works at all, separate from the automated detection issue.

---

**End of Troubleshooting Workflow**
