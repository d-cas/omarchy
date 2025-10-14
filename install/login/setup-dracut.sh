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
  echo "========================================="

  # Robust approach: Trace backward from root mount to find LUKS container
  luks_uuid=""
  luks_dev=""

  # Step 1: Get the root source device (should be /dev/mapper/something for encrypted)
  root_source=$(findmnt -n -o SOURCE / 2>/dev/null)
  echo "DEBUG: Root source from findmnt: '$root_source'"

  if [ -z "$root_source" ]; then
    echo "DEBUG: WARNING - findmnt returned empty for root source!"
    echo "DEBUG: Trying alternate method with /proc/mounts..."
    root_source=$(awk '$2 == "/" {print $1}' /proc/mounts 2>/dev/null | head -1)
    echo "DEBUG: Root source from /proc/mounts: '$root_source'"
  fi

  # Step 2: Check if root is on a mapper device (encrypted)
  if [[ "$root_source" == /dev/mapper/* ]]; then
    echo "DEBUG: Root is on mapper device - attempting to find backing LUKS device"

    # Try cryptsetup status to get the backing device
    echo "DEBUG: Running: cryptsetup status '$root_source'"
    status_output=$(cryptsetup status "$root_source" 2>&1)
    echo "DEBUG: cryptsetup status output:"
    echo "$status_output" | while IFS= read -r line; do echo "DEBUG:   $line"; done

    luks_dev=$(echo "$status_output" | grep "device:" | awk '{print $2}')
    echo "DEBUG: Extracted backing device: '$luks_dev'"

    if [ -n "$luks_dev" ] && [ -b "$luks_dev" ]; then
      echo "DEBUG: Backing device $luks_dev exists, getting LUKS UUID..."
      luks_uuid=$(cryptsetup luksUUID "$luks_dev" 2>&1)
      echo "DEBUG: LUKS UUID: '$luks_uuid'"

      if [ -n "$luks_uuid" ]; then
        echo "DEBUG: *** SUCCESS - Found LUKS device ***"
        echo "DEBUG: Device: $luks_dev"
        echo "DEBUG: UUID: $luks_uuid"
      else
        echo "DEBUG: ERROR - luksUUID returned empty for $luks_dev"
      fi
    else
      echo "DEBUG: ERROR - Backing device '$luks_dev' not found or not a block device"
    fi
  else
    echo "DEBUG: Root source is NOT a mapper device: '$root_source'"
    echo "DEBUG: This appears to be an unencrypted system"
  fi

  # Step 3: Build cmdline based on what we found
  if [ -n "$luks_uuid" ]; then
    echo "DEBUG: *** ENCRYPTED ROOT PATH ***"

    # Get root filesystem info for additional parameters
    root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null)
    root_opts=""
    echo "DEBUG: Root fstype: $root_fstype"

    if [ "$root_fstype" = "btrfs" ]; then
      root_subvol=$(findmnt -n -o OPTIONS / 2>/dev/null | grep -oP 'subvol=\K[^,]+' || echo "@")
      root_opts="rootflags=subvol=$root_subvol rootfstype=btrfs"
      echo "DEBUG: Btrfs subvol: $root_subvol"
      echo "DEBUG: Root opts: $root_opts"
    fi

    # Build dracut-compatible cmdline
    cmdline="rd.luks.uuid=$luks_uuid rd.luks.name=${luks_uuid}=root root=/dev/mapper/root $root_opts rw"
    echo "DEBUG: Generated LUKS cmdline: $cmdline"
  else
    # No LUKS found - unencrypted root
    echo "DEBUG: *** UNENCRYPTED ROOT FALLBACK PATH ***"

    root_uuid=$(findmnt -n -o UUID / 2>/dev/null)
    echo "DEBUG: Root UUID from findmnt: '$root_uuid'"

    if [ -n "$root_uuid" ]; then
      cmdline="root=UUID=$root_uuid rw"
      echo "DEBUG: Using filesystem UUID for unencrypted root: $root_uuid"
    elif [ -n "$root_source" ]; then
      cmdline="root=$root_source rw"
      echo "DEBUG: Using root source: $root_source"
    else
      echo "DEBUG: ERROR - Could not determine root device"
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
