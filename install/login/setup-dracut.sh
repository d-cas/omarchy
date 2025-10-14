#!/usr/bin/env bash

echo "Setting up dracut initramfs generation..."

# Install base dracut configuration
if [ -f "$OMARCHY_INSTALL/config/dracut/10-omarchy.conf" ]; then
  echo "Installing base dracut configuration..."
  sudo install -Dm644 "$OMARCHY_INSTALL/config/dracut/10-omarchy.conf" /etc/dracut.conf.d/10-omarchy.conf
  echo "Base configuration installed: /etc/dracut.conf.d/10-omarchy.conf"
else
  echo "Warning: Base dracut config not found at $OMARCHY_INSTALL/config/dracut/10-omarchy.conf"
fi

# Install hardware-specific configurations if they exist
if [ -f "$OMARCHY_INSTALL/config/dracut/20-apple-t2.conf" ]; then
  echo "Installing Apple T2 configuration..."
  sudo install -Dm644 "$OMARCHY_INSTALL/config/dracut/20-apple-t2.conf" /etc/dracut.conf.d/20-apple-t2.conf
fi

if [ -f "$OMARCHY_INSTALL/config/dracut/21-apple-spi.conf" ]; then
  echo "Installing Apple SPI configuration..."
  sudo install -Dm644 "$OMARCHY_INSTALL/config/dracut/21-apple-spi.conf" /etc/dracut.conf.d/21-apple-spi.conf
fi

if [ -f "$OMARCHY_INSTALL/config/dracut/30-nvidia.conf" ]; then
  echo "Installing NVIDIA configuration..."
  sudo install -Dm644 "$OMARCHY_INSTALL/config/dracut/30-nvidia.conf" /etc/dracut.conf.d/30-nvidia.conf
fi

# Install Limine integration pacman hook
#if [ -f "$OMARCHY_INSTALL/config/hooks/95-limine-dracut.hook" ]; then
#  echo "Installing Limine dracut integration hook..."
#  sudo install -Dm644 "$OMARCHY_INSTALL/config/hooks/95-limine-dracut.hook" /usr/share/libalpm/hooks/95-limine-dracut.hook
#  echo "Limine hook installed: /usr/share/libalpm/hooks/95-limine-dracut.hook"
#else
#  echo "Warning: Limine hook not found at $OMARCHY_INSTALL/config/hooks/95-limine-dracut.hook"
#fi

# Re-enable dracut hooks (reverse what disable-dracut-hooks.sh did)
echo "Re-enabling dracut pacman hooks..."

if [ -f /usr/share/libalpm/hooks/90-dracut-install.hook.disabled ]; then
  sudo mv /usr/share/libalpm/hooks/90-dracut-install.hook.disabled /usr/share/libalpm/hooks/90-dracut-install.hook
  echo "Re-enabled: 90-dracut-install.hook"
fi

if [ -f /usr/share/libalpm/hooks/60-dracut-remove.hook.disabled ]; then
  sudo mv /usr/share/libalpm/hooks/60-dracut-remove.hook.disabled /usr/share/libalpm/hooks/60-dracut-remove.hook
  echo "Re-enabled: 60-dracut-remove.hook"
fi

echo "dracut hooks re-enabled"

# Generate initial dracut images for all installed kernels
echo "Generating initramfs images for all installed kernels..."
if command -v dracut &>/dev/null; then
  sudo dracut --force --hostonly --regenerate-all
  echo "Initramfs generation complete"
else
  echo "Warning: dracut command not found - skipping initramfs generation"
fi

echo "dracut setup complete"

# Create initial boot entry manually (limine-snapper-sync will update on first boot)
echo "Creating initial boot entry..."

# Determine correct limine.conf location
if [[ -d /sys/firmware/efi ]]; then
  # EFI system
  if [[ -f /boot/EFI/BOOT/limine.conf ]]; then
    limine_config="/boot/EFI/BOOT/limine.conf"
  else
    limine_config="/boot/EFI/limine/limine.conf"
  fi
else
  # BIOS system
  limine_config="/boot/limine/limine.conf"
fi

# Get kernel version
kernel_version=$(ls /boot/vmlinuz-* 2>/dev/null | head -1 | sed 's/.*vmlinuz-//')
if [ -z "$kernel_version" ]; then
  echo "Warning: No kernel found in /boot"
else
  # Get initramfs path
  initramfs_path="/boot/initramfs-${kernel_version}.img"

  # IMPORTANT: Do NOT use /etc/default/limine - it has mkinitcpio syntax
  # We must detect LUKS ourselves and use dracut syntax

  echo "========================================="
  echo "DEBUG: Starting LUKS detection for dracut"
  echo "DEBUG: PWD = $(pwd)"
  echo "DEBUG: /sys/class/block exists? $([ -d /sys/class/block ] && echo YES || echo NO)"
  echo "DEBUG: /dev exists? $([ -d /dev ] && echo YES || echo NO)"
  echo "DEBUG: /proc exists? $([ -d /proc ] && echo YES || echo NO)"
  echo "========================================="

  # Scan for LUKS devices directly (works even without /proc mounted in chroot)
  luks_uuid=""
  luks_dev=""

  # Try cryptsetup status first (works if running outside chroot with mapper active)
  echo "DEBUG: Trying cryptsetup status root..."
  if cryptsetup status root &>/dev/null; then
    luks_dev=$(cryptsetup status root | grep "device:" | awk '{print $2}')
    luks_uuid=$(cryptsetup luksUUID "$luks_dev" 2>/dev/null)
    echo "DEBUG: SUCCESS - Found LUKS via cryptsetup status: $luks_dev (UUID: $luks_uuid)"
  else
    echo "DEBUG: cryptsetup status root FAILED"
  fi

  # If that didn't work, scan /sys/class/block (available in chroot)
  if [ -z "$luks_uuid" ]; then
    echo "DEBUG: Scanning /sys/class/block for LUKS devices..."
    echo "DEBUG: Block devices found: $(ls /sys/class/block/ 2>/dev/null | tr '\n' ' ')"

    for blockdev in /sys/class/block/*; do
      devname="/dev/$(basename "$blockdev")"
      echo "DEBUG: Checking $devname..."

      # Skip loop devices, ram, and non-partition devices without numbers
      if [[ "$devname" == /dev/loop* ]]; then
        echo "DEBUG: Skipping loop device $devname"
        continue
      fi
      if [[ "$devname" == /dev/ram* ]]; then
        echo "DEBUG: Skipping ram device $devname"
        continue
      fi
      if [[ ! "$devname" =~ [0-9]$ ]]; then
        echo "DEBUG: Skipping non-partition $devname (no number suffix)"
        continue
      fi

      # Check if device exists and is block device
      if [ ! -b "$devname" ]; then
        echo "DEBUG: $devname is not a block device or doesn't exist"
        continue
      fi

      # Check if it's a LUKS device
      echo "DEBUG: Running cryptsetup isLuks on $devname..."
      if cryptsetup isLuks "$devname" 2>/dev/null; then
        echo "DEBUG: $devname IS a LUKS device!"
        luks_uuid=$(cryptsetup luksUUID "$devname" 2>/dev/null)
        if [ -n "$luks_uuid" ]; then
          echo "DEBUG: SUCCESS - Found LUKS device: $devname with UUID: $luks_uuid"
          luks_dev="$devname"
          break
        else
          echo "DEBUG: WARNING - $devname is LUKS but luksUUID failed"
        fi
      else
        echo "DEBUG: $devname is not a LUKS device"
      fi
    done

    if [ -z "$luks_uuid" ]; then
      echo "DEBUG: SCAN COMPLETE - No LUKS devices found!"
    fi
  fi

  # If we found a LUKS device, configure for encrypted root
  if [ -n "$luks_uuid" ]; then
    echo "DEBUG: *** ENCRYPTED ROOT PATH ***"
    echo "DEBUG: Using LUKS UUID: $luks_uuid"

    # Get root filesystem info for additional parameters (may fail in chroot, that's OK)
    root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null)
    root_opts=""
    echo "DEBUG: Root fstype: $root_fstype"

    if [ "$root_fstype" = "btrfs" ]; then
      root_subvol=$(findmnt -n -o OPTIONS / 2>/dev/null | grep -oP 'subvol=\K[^,]+' || echo "@")
      root_opts="rootflags=subvol=$root_subvol rootfstype=btrfs"
      echo "DEBUG: Btrfs subvol: $root_subvol"
    fi

    # Build dracut-compatible cmdline
    cmdline="rd.luks.uuid=$luks_uuid rd.luks.name=${luks_uuid}=root root=/dev/mapper/root $root_opts rw"
    echo "DEBUG: Generated LUKS cmdline: $cmdline"
  else
    # No LUKS found - unencrypted root
    echo "DEBUG: *** UNENCRYPTED ROOT FALLBACK PATH ***"
    echo "DEBUG: WARNING - Using fallback logic (this generates WRONG UUID for encrypted systems!)"

    root_source=$(findmnt -n -o SOURCE / 2>/dev/null)
    root_uuid=$(findmnt -n -o UUID / 2>/dev/null)
    echo "DEBUG: root_source from findmnt: $root_source"
    echo "DEBUG: root_uuid from findmnt: $root_uuid"

    if [ -n "$root_uuid" ]; then
      cmdline="root=UUID=$root_uuid rw"
      echo "DEBUG: Using filesystem UUID (WRONG for encrypted!): $root_uuid"
    elif [ -n "$root_source" ]; then
      cmdline="root=$root_source rw"
      echo "DEBUG: Using root source: $root_source"
    else
      echo "DEBUG: Could not detect root device at all"
      cmdline="root=/dev/mapper/root rw"
    fi
  fi

  echo "DEBUG: FINAL cmdline = $cmdline"
  echo "========================================="

  # Append to correct limine.conf location
  echo "Adding boot entry to ${limine_config} for kernel ${kernel_version}..."
  sudo tee -a "${limine_config}" <<EOF >/dev/null

# Default Omarchy Boot Entry
/Omarchy
  protocol: linux
  kernel_path: boot():/vmlinuz-${kernel_version}
  module_path: boot():/initramfs-${kernel_version}.img
  cmdline: ${cmdline}
EOF

  echo "Boot entry created successfully at ${limine_config}"
  echo "limine-snapper-sync.service will manage entries on subsequent boots"
fi
