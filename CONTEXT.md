# Omarchy Dracut Migration - Context & Current State

**Last Updated**: 2025-10-19
**Branch**: `dracut`
**Repository**: `git@github.com:d-cas/omarchy.git`
**Status**: CRITICAL FIX COMMITTED - Ready for testing

---

## The Mission

Migrating Omarchy from **mkinitcpio** to **dracut** for initramfs generation to fix a critical bug: **FIDO2 multi-token unlock hangs the system at boot**.

**Root Problem**: mkinitcpio cannot handle multiple FIDO2 tokens enrolled for LUKS unlock - it hangs with "Multiple FIDO2 tokens enrolled, cannot automatically determine token."

**Solution**: dracut handles multi-token scenarios correctly by prompting the user to touch any enrolled key.

---

## The Boot Failure We Were Debugging

### Symptom
Fresh Omarchy installations with LUKS encryption dropped into **dracut emergency shell** with error:
```
Warning: /dev/disk/by-uuid/7865e767-af55-4d57-a4e2-6454bfb62ac2 does not exist
```

This UUID was the **filesystem UUID** (wrong) instead of the **LUKS UUID** (correct).

### Root Cause Discovery (Oct 19, 2025)

The problem was **NOT** LUKS detection failure. It was a **boot config generation issue**:

1. **archinstall** creates `/boot/limine.conf` with mkinitcpio-style parameters (`cryptdevice=PARTUUID=...`) BEFORE our Omarchy scripts run
2. Our `setup-dracut.sh` was **appending** (`tee -a`) dracut-compatible entries to this file
3. The bootloader loaded the **FIRST entry** (archinstall's broken one) → wrong UUID → emergency shell
4. Our correct dracut entry was ignored because it came second

### The Fix: "Hostile Takeover"

**File**: `install/login/setup-dracut.sh` (line 191)

**Changed from** (append):
```bash
sudo tee -a "${limine_config}" <<EOF >/dev/null
```

**Changed to** (overwrite):
```bash
sudo tee "${limine_config}" <<EOF >/dev/null
```

**Complete Solution**:
- Completely **overwrite** archinstall's broken limine.conf
- Include full config (header + branding + colors + boot entry)
- Use dracut-compatible boot parameters: `rd.luks.uuid=<LUKS-UUID> rd.luks.name=<LUKS-UUID>=root root=/dev/mapper/root`
- Added BREADCRUMB logging to track the overwrite

**Result**: Only dracut-compatible boot entries remain, archinstall's broken config is eliminated.

---

## How the Boot Flow Works

### archinstall Execution Order (The Trap)
1. LUKS setup
2. Package installation
3. **Bootloader config creation** ← archinstall writes broken limine.conf here
4. **Custom scripts run** ← Our Omarchy scripts run here (too late to prevent #3)

### Omarchy Install Script Execution Order
Located in `install/login/all.sh`:
1. `plymouth.sh` - Sets up boot splash
2. `limine-snapper.sh` - Creates `/etc/default/limine` with LUKS detection
3. **`setup-dracut.sh`** ← **HOSTILE TAKEOVER happens here** (overwrites archinstall's config)
4. `alt-bootloaders.sh` - Handles non-Limine bootloaders

### Critical Files

**`install/login/setup-dracut.sh`** (Primary script):
- Installs dracut config files from `install/config/dracut/`
- Generates dracut initramfs for all kernels
- **Line 191**: Overwrites `/boot/limine.conf` with complete dracut-compatible config
- Uses robust LUKS detection (traces from root mount → mapper device → backing LUKS device)

**`install/config/dracut/10-omarchy.conf`** (dracut config):
```bash
add_dracutmodules+=" systemd systemd-initrd base kernel-modules "
add_dracutmodules+=" plymouth crypt systemd-cryptsetup "
# FIDO2 temporarily disabled for initial password-only testing:
# add_dracutmodules+=" fido2 "
force_drivers+=" btrfs "
hostonly="yes"
compress="zstd"
```

**`install/login/limine-snapper.sh`**:
- Creates `/etc/default/limine` with KERNEL_CMDLINE
- Enables limine-snapper-sync.service for snapshot booting

---

## LUKS Detection Logic

### How We Detect Encrypted Root

**Method** (lines 89-184 in setup-dracut.sh):
1. Check if `cryptsetup status root` succeeds (indicates encryption)
2. Extract backing device path (e.g., `/dev/vda2`)
3. Get LUKS UUID: `cryptsetup luksUUID /dev/vda2`
4. Build cmdline: `root=/dev/mapper/root rd.luks.uuid=$luks_uuid rd.luks.name=${luks_uuid}=root`

**Fallback** (unencrypted):
- Get filesystem UUID from `findmnt`
- Build cmdline: `root=UUID=$root_uuid`

**Key Insight**: We **cannot** trust `/etc/default/limine` because it may contain archinstall's mkinitcpio-style parameters. We must detect LUKS ourselves.

---

## Correct Boot Parameters

### LUKS Encrypted System (dracut syntax)
```
rd.luks.uuid=d5a12cb5-52e0-4e76-a896-0e0b2eababf6
rd.luks.name=d5a12cb5-52e0-4e76-a896-0e0b2eababf6=root
root=/dev/mapper/root
rw quiet splash
```

### Wrong (mkinitcpio syntax - what archinstall creates)
```
cryptdevice=PARTUUID=xxx root=UUID=<filesystem-uuid>
```

**UUID Hierarchy**:
```
Physical Device: /dev/vda2
  └─ LUKS Container (UUID: d5a12cb5...) ← Need this for rd.luks.uuid
      └─ /dev/mapper/root (when unlocked)
          └─ Filesystem (UUID: c8760d62...) ← NOT this one!
```

---

## Current Status & Next Steps

### Status: FIX COMMITTED (Commit 51c5bdb)
- ✅ Hostile takeover implemented
- ✅ BREADCRUMB logging added
- ✅ Ready to push and test

### Immediate Next Steps

1. **Push to GitHub**:
   ```bash
   cd /home/dcas/truenas/dev-projects/omarchy_repos/omarchy-dracut
   git push origin dracut
   ```

2. **Build ISO**:
   ```bash
   cd /home/dcas/truenas/dev-projects/omarchy_repos/omarchy-iso
   ./bin/omarchy-iso-make --no-cache --no-boot-offer
   ```

   The ISO builder is configured to pull from:
   - Repo: `d-cas/omarchy` (your fork)
   - Branch: `dracut`

3. **Test Installation**:
   - Fresh install with LUKS encryption
   - Watch for BREADCRUMB output showing "HOSTILE TAKEOVER"
   - Verify `/boot/limine.conf` contains ONLY Omarchy entry with dracut params
   - System should boot to LUKS password prompt (not emergency shell)

4. **If Successful**:
   - Test password unlock to desktop
   - Re-enable FIDO2 module in `10-omarchy.conf`
   - Test multi-token FIDO2 unlock (PRIMARY GOAL)

---

## Debugging & Verification

### Check Boot Config After Install
```bash
# Mount the installed system
sudo mount /dev/vda3 /mnt  # (adjust device as needed)
sudo mount /dev/vda1 /mnt/boot  # (EFI partition)

# Check the config
cat /mnt/boot/limine.conf
# Should show:
# - Omarchy branding
# - ONLY one boot entry: "/Omarchy"
# - cmdline with rd.luks.uuid=...
# - NO archinstall entries
```

### BREADCRUMB Output During Install
Look for these in console/logs:
```
BREADCRUMB: Starting LUKS detection for dracut cmdline...
BREADCRUMB: cryptsetup status root succeeded - system is encrypted
BREADCRUMB: LUKS UUID detected: d5a12cb5-...
BREADCRUMB: ✓ ENCRYPTED ROOT - Using dracut LUKS parameters
BREADCRUMB: Performing HOSTILE TAKEOVER of /boot/limine.conf...
BREADCRUMB: ✓ /boot/limine.conf OVERWRITTEN successfully
```

### If Boot Still Fails
Check what UUID is being used:
```bash
# In dracut emergency shell
cat /proc/cmdline
# Should show: rd.luks.uuid=<LUKS-UUID>, NOT root=UUID=<filesystem-UUID>
```

---

## Key Commits in History

| Commit | Date | Description |
|--------|------|-------------|
| `51c5bdb` | Oct 19 | **Hostile takeover fix** - Overwrite archinstall's config |
| `ebef60d` | Oct 14 | Trace from root mount to LUKS device |
| `d6f7a24` | Oct 9 | Add rd.luks.name parameter |
| `1435a36` | Oct 9 | Remove fido2 module for testing |
| `6fea5f6` | Oct 8 | Initial mkinitcpio → dracut migration |

---

## Project Structure

```
omarchy-dracut/              # Working repository (your fork)
├── install/
│   ├── login/
│   │   ├── setup-dracut.sh       ← HOSTILE TAKEOVER here
│   │   ├── limine-snapper.sh     ← LUKS detection for /etc/default/limine
│   │   └── all.sh                ← Execution order
│   └── config/
│       └── dracut/
│           ├── 10-omarchy.conf   ← Base dracut config
│           ├── 20-apple-t2.conf
│           ├── 21-apple-spi.conf
│           └── 30-nvidia.conf
├── CONTEXT.md               ← This file
├── PROJECT-STATUS.md        ← Detailed session history
├── MIGRATION-SUMMARY.md     ← Migration strategy
└── ANALYSIS.md              ← Full dependency analysis
```

---

## Success Criteria

**Phase 1: Boot to Password Prompt** (Current Focus)
- [x] Install completes without errors
- [x] Hostile takeover overwrites archinstall's config
- [ ] System boots to LUKS password prompt (not emergency shell)
- [ ] Password unlock works
- [ ] System reaches desktop

**Phase 2: FIDO2 Multi-Token** (Primary Goal)
- [ ] Re-enable fido2 module
- [ ] Enroll multiple FIDO2 tokens
- [ ] System prompts for token at boot
- [ ] Any enrolled token unlocks successfully
- [ ] **No hang with multiple tokens** (the bug we're fixing)

**Phase 3: Production Ready**
- [ ] Kernel updates regenerate initramfs
- [ ] Snapshot booting works
- [ ] All hardware configs tested (NVIDIA, Apple T2/SPI)
- [ ] Merge dracut branch to master

---

## Reference Links

**Key Upstream Issues**:
- mkinitcpio FIDO2 multi-token hang (original problem)
- archinstall + dracut integration challenges

**Documentation**:
- dracut.cmdline(7) - Boot parameter syntax
- cryptsetup(8) - LUKS device management
- systemd-cryptsetup - dracut LUKS unlock module

---

## Quick Recovery Commands

**If you need to start fresh**:
```bash
# Current working directory
cd /home/dcas/truenas/dev-projects/omarchy_repos/omarchy-dracut

# Current branch
git checkout dracut

# Latest fix
git log -1 --oneline  # Should show: 51c5bdb fix: hostile takeover...

# Check what's modified
git status

# See the hostile takeover code
grep -A5 "HOSTILE TAKEOVER" install/login/setup-dracut.sh
```

**End of Context**
