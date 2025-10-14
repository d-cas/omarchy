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

  echo "Detecting LUKS configuration for dracut..."

  # Find the LUKS partition - try common locations and check all partitions
  luks_dev=""
  for dev in /dev/vda2 /dev/sda2 /dev/nvme0n1p2 /dev/vda3 /dev/sda3 /dev/nvme0n1p3; do
    if [ -b "$dev" ] && cryptsetup isLuks "$dev" 2>/dev/null; then
      luks_dev="$dev"
      break
    fi
  done

  # If not found in common locations, scan all partitions
  if [ -z "$luks_dev" ]; then
    for dev in /dev/vd* /dev/sd* /dev/nvme*; do
      if [ -b "$dev" ] && [[ "$dev" =~ [0-9]$ ]] && cryptsetup isLuks "$dev" 2>/dev/null; then
        luks_dev="$dev"
        break
      fi
    done
  fi

  if [ -n "$luks_dev" ]; then
    # Get the LUKS UUID (not PARTUUID!)
    luks_uuid=$(cryptsetup luksUUID "$luks_dev" 2>/dev/null)

    if [ -n "$luks_uuid" ]; then
      echo "Found LUKS device $luks_dev with LUKS UUID: $luks_uuid"

      # Get root filesystem info for additional parameters
      root_fstype=$(findmnt -n -o FSTYPE /)
      root_opts=""

      if [ "$root_fstype" = "btrfs" ]; then
        root_subvol=$(findmnt -n -o OPTIONS / | grep -oP 'subvol=\K[^,]+' || echo "@")
        root_opts="rootflags=subvol=$root_subvol rootfstype=btrfs"
      fi

      # Build dracut-compatible cmdline
      cmdline="rd.luks.uuid=$luks_uuid rd.luks.name=${luks_uuid}=root root=/dev/mapper/root $root_opts rw"
      echo "Generated cmdline: $cmdline"
    else
      echo "Warning: Could not get LUKS UUID from $luks_dev"
    fi
  fi

  # Final fallback
  if [ -z "$cmdline" ]; then

    # Final fallback if no LUKS found
    if [ -z "$cmdline" ]; then
      root_uuid=$(findmnt -n -o UUID / 2>/dev/null || echo "")
      if [ -n "$root_uuid" ]; then
        cmdline="root=UUID=$root_uuid rw"
      else
        cmdline="root=/dev/mapper/root rw"
        echo "Warning: Could not detect root device, using generic fallback"
      fi
    fi
  fi

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
