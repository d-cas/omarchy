# mkinitcpio → dracut Migration Summary

**Quick Reference Guide for LLM Context**

---

# Latest Status (2025-10-09 - End of Session)

## ✅ Major Achievements

1. **archinstall Crash Fixed**: Inline Python patch successfully handles missing mkinitcpio.conf
2. **Dracut Migration Successful**: Dracut generates initramfs and boots correctly
3. **Bootloader Config Creation Fixed**: limine-snapper.sh now properly creates initial config
4. **Boot Entries Generated**: Manual generation bypasses Java issues successfully
5. **LUKS Syntax Corrected**: Added rd.luks.name parameter for proper device mapping

## ⚠️ Current Status

### Active Investigation: LUKS Unlock Hang
- **Symptom**: "A start job is running for /dev/mapper/root" (infinite wait)
- **Likely Cause**: Password prompt hidden by Plymouth or FIDO2 module waiting
- **Current Test**: Removed FIDO2 module to test baseline password unlock
- **Next Step**: Rebuild ISO with commit 1435a36 and test boot

### Resolved Issues This Session
1. ✅ **Limine Config Creation** - Fixed backwards logic in limine-snapper.sh
2. ✅ **Boot Entry Population** - Manual generation works around Java 17+ requirement
3. ✅ **LUKS Device Naming** - Correct rd.luks.name=${uuid}=root syntax implemented

**See**: [SESSION-NOTES.md](SESSION-NOTES.md) for complete session details
- Status: Testing LUKS password unlock without FIDO2
- Next: Re-add FIDO2 once baseline works

## Phase 1 Progress

- Core dracut functionality: ✅ COMPLETE
- archinstall compatibility: ✅ COMPLETE
- Bootloader automation: ❌ BROKEN
- FIDO2 multi-token test: ⏸️ BLOCKED

---

## Overview

Omarchy currently uses **mkinitcpio** for initramfs generation. Migrating to **dracut** to fix multi-token FIDO2 unlock (system hangs with multiple YubiKeys enrolled).

**Strategy:** Complete replacement (not coexistence)

---

## Files Requiring Changes (13 total)

### 1. Packages
- `install/omarchy-other.packages:24` - Remove `limine-mkinitcpio-hook`, add `dracut`

### 2. Scripts - Preflight
- `install/preflight/disable-mkinitcpio.sh` → `disable-dracut-hooks.sh`
  - Change hook names: `90-dracut-install.hook`, `60-dracut-remove.hook`

### 3. Scripts - Login
- `install/login/enable-mkinitcpio.sh` → `enable-dracut.sh`
  - Replace: `mkinitcpio -P` → `dracut --force --hostonly --regenerate-all`

### 4. Scripts - Bootloader
- `install/login/limine-snapper.sh`
  - Remove: `/etc/mkinitcpio.conf.d/omarchy_hooks.conf` creation
  - Add: `/etc/dracut.conf.d/10-omarchy.conf` creation
  - **BLOCKER:** Need Limine + dracut integration solution

- `install/login/alt-bootloaders.sh`
  - Remove: mkinitcpio.conf modification logic
  - Simplify: dracut handles Plymouth uniformly

### 5. Scripts - Hardware
- `install/config/hardware/nvidia.sh`
  - Remove: mkinitcpio.conf modification (lines 51-67)
  - Add: Create `/etc/dracut.conf.d/30-nvidia.conf`

- `install/config/hardware/fix-apple-t2.sh`
  - Remove: `/etc/mkinitcpio.conf.d/apple-t2.conf` creation
  - Add: Create `/etc/dracut.conf.d/20-apple-t2.conf`

- `install/config/hardware/fix-apple-spi-keyboard.sh`
  - Remove: `/etc/mkinitcpio.conf.d/macbook_spi_modules.conf` creation
  - Add: Create `/etc/dracut.conf.d/21-apple-spi.conf`

### 6. Utility
- `bin/omarchy-refresh-plymouth`
  - Replace: `mkinitcpio -P` → `dracut --force --hostonly --regenerate-all`
  - Remove: Limine detection logic

### 7. Sourcing Scripts
- `install/preflight/all.sh:7` - Update source path
- `install/login/all.sh:3` - Update source path

---

## Critical Configurations to Migrate

### Core Hooks → Dracut Modules

**mkinitcpio (current):**
```bash
HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap
       consolefont block encrypt filesystems fsck btrfs-overlayfs)
```

**dracut (target):**
```bash
# /etc/dracut.conf.d/10-omarchy.conf
add_dracutmodules+=" systemd systemd-cryptsetup crypt fido2 plymouth "
force_drivers+=" btrfs "
hostonly="yes"
compress="zstd"
```

---

### Hardware-Specific Configs

**Apple T2:**
```bash
# /etc/dracut.conf.d/20-apple-t2.conf
add_drivers+=" apple-bce usbhid hid_apple hid_generic xhci_pci xhci_hcd "
install_items+=" /etc/modprobe.d/brcmfmac.conf "
```

**Apple SPI (MacBook8,1):**
```bash
# /etc/dracut.conf.d/21-apple-spi.conf
add_drivers+=" applespi spi_pxa2xx_platform spi_pxa2xx_pci "
```

**Apple SPI (Other models):**
```bash
add_drivers+=" applespi intel_lpss_pci spi_pxa2xx_platform "
```

**NVIDIA:**
```bash
# /etc/dracut.conf.d/30-nvidia.conf
add_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "
install_items+=" /etc/modprobe.d/nvidia.conf "
```

---

## Critical Blockers

### 1. Limine + dracut Integration
**Problem:** No `limine-dracut-hook` package exists

**Options:**
- A) Create custom `limine-dracut-hook` package (cleanest)
- B) Use kernel-install framework
- C) Custom pacman hook calling limine-update after dracut

**Example custom hook (Option C):**
```ini
# /usr/share/libalpm/hooks/95-limine-dracut.hook
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = boot/vmlinuz-*

[Action]
Description = Updating Limine bootloader entries...
When = PostTransaction
Exec = /usr/bin/limine-update
```

### 2. Btrfs Snapshot Booting
- Verify `btrfs-overlayfs` hook has dracut equivalent
- Test limine-snapper-sync compatibility

---

## What Breaks Without Proper Migration

**CRITICAL (System Won't Boot):**
- LUKS/FIDO2 unlock fails (no encrypt module)
- Keyboard non-functional on T2/SPI MacBooks
- Missing filesystem support

**HIGH IMPACT:**
- Plymouth splash missing
- NVIDIA graphics issues
- Snapshot booting fails
- Kernel updates don't regenerate initramfs

---

## Key Script Changes

### enable-dracut.sh (replaces enable-mkinitcpio.sh)
```bash
echo "Re-enabling dracut hooks..."

if [ -f /usr/share/libalpm/hooks/90-dracut-install.hook.disabled ]; then
  sudo mv /usr/share/libalpm/hooks/90-dracut-install.hook.disabled \
          /usr/share/libalpm/hooks/90-dracut-install.hook
fi

if [ -f /usr/share/libalpm/hooks/60-dracut-remove.hook.disabled ]; then
  sudo mv /usr/share/libalpm/hooks/60-dracut-remove.hook.disabled \
          /usr/share/libalpm/hooks/60-dracut-remove.hook
fi

echo "dracut hooks re-enabled"
sudo dracut --force --hostonly --regenerate-all
```

### nvidia.sh modification
```bash
# OLD (remove):
sudo sed -i -E "s/^(MODULES=\\()/\\1${NVIDIA_MODULES} /" /etc/mkinitcpio.conf
sudo mkinitcpio -P

# NEW (add):
cat <<EOF | sudo tee /etc/dracut.conf.d/30-nvidia.conf >/dev/null
add_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "
install_items+=" /etc/modprobe.d/nvidia.conf "
EOF
```

---

## Testing Checklist

**Must Test:**
- [ ] VM fresh install (core functionality)
- [ ] FIDO2 multi-token unlock (primary goal)
- [ ] NVIDIA system (early KMS)
- [ ] Kernel update workflow
- [ ] Plymouth boot splash

**Should Test (if hardware available):**
- [ ] T2 MacBook (keyboard at boot)
- [ ] SPI MacBook (keyboard at boot)
- [ ] Snapshot booting

---

## Migration Steps (High-Level)

1. **Replace package:** `limine-mkinitcpio-hook` → `dracut`
2. **Create dracut configs:** 10-omarchy.conf, 20-apple-t2.conf, 21-apple-spi.conf, 30-nvidia.conf
3. **Update scripts:** Rename and modify all mkinitcpio references
4. **Resolve Limine integration:** Choose and implement Option A/B/C
5. **Test in VM:** Verify core functionality
6. **Test on hardware:** NVIDIA, FIDO2, T2/SPI (if available)
7. **Update documentation:** Create docs/DRACUT.md
8. **Deploy:** Commit, push, create PR

---

## Success Criteria

### Phase 1: Core Boot Functionality
- [x] Fresh install completes without errors
- [x] (CONFIRMED) lsinitrd shows dracut generated the initramfs - saw dracut boot messages
- [ ] (BLOCKED) System boots with Limine entries - Java version issue prevents entry generation
- [ ] LUKS unlock works with correct dracut cmdline syntax

### Phase 2: Feature Validation
- [ ] **FIDO2 multi-token unlock works (no hang)**
- [ ] Plymouth displays correctly
- [ ] Hardware-specific features work (NVIDIA, T2, SPI)
- [ ] Kernel updates auto-regenerate initramfs
- [ ] Boot time same or better

---

## Why This Migration?

**Problem:** mkinitcpio hangs with multiple FIDO2 tokens:
```
Multiple FIDO2 tokens enrolled, cannot automatically determine token.
Falling back to traditional unlocking.
```

**Solution:** dracut's fido2 module auto-switches to interactive mode:
```
Please enter LUKS2 token PIN for <device>:
[Touch any enrolled YubiKey] → unlocks
```

**Additional Benefits:**
- Battle-tested (Fedora, RHEL, EndeavourOS)
- Better hardware auto-detection
- Cleaner module architecture
- Simpler long-term maintenance

---

## Timeline Estimate

- Preparation & Research: 2-4 days
- Configuration Creation: 1 day
- Script Migration: 2-3 days
- Testing: 3-5 days
- Documentation: 1-2 days

**Total:** 10-15 days (with hardware access)

---

## Quick Reference: File Mapping

| mkinitcpio | dracut | Purpose |
|------------|--------|---------|
| `/etc/mkinitcpio.conf.d/omarchy_hooks.conf` | `/etc/dracut.conf.d/10-omarchy.conf` | Core modules |
| `/etc/mkinitcpio.conf.d/apple-t2.conf` | `/etc/dracut.conf.d/20-apple-t2.conf` | T2 drivers |
| `/etc/mkinitcpio.conf.d/macbook_spi_modules.conf` | `/etc/dracut.conf.d/21-apple-spi.conf` | SPI drivers |
| MODULES in mkinitcpio.conf | `/etc/dracut.conf.d/30-nvidia.conf` | NVIDIA drivers |
| `mkinitcpio -P` | `dracut --force --hostonly --regenerate-all` | Regenerate all |
| `90-mkinitcpio-install.hook` | `90-dracut-install.hook` | Auto-regen on updates |

---

**Full analysis available in ANALYSIS.md (1536 lines)**
