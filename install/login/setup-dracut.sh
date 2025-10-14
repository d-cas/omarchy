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

  # Check if root is on an encrypted device
  root_source=$(findmnt -n -o SOURCE /)

  if [[ "$root_source" == /dev/mapper/* ]]; then
    echo "Encrypted root detected: $root_source"

    # Try cryptsetup status first (works if running outside chroot)
    if cryptsetup status root &>/dev/null; then
      luks_dev=$(cryptsetup status root | grep "device:" | awk '{print $2}')
      luks_uuid=$(cryptsetup luksUUID "$luks_dev" 2>/dev/null)
    fi

    # If that didn't work (e.g., in chroot), scan /sys/class/block
    if [ -z "$luks_uuid" ]; then
      echo "Scanning block devices for LUKS container..."
      for blockdev in /sys/class/block/*; do
        devname="/dev/$(basename "$blockdev")"
        # Skip loop devices, ram, and non-partition devices without numbers
        [[ "$devname" == /dev/loop* ]] && continue
        [[ "$devname" == /dev/ram* ]] && continue
        [[ ! "$devname" =~ [0-9]$ ]] && continue

        # Check if it's a LUKS device
        if [ -b "$devname" ] && cryptsetup isLuks "$devname" 2>/dev/null; then
          luks_uuid=$(cryptsetup luksUUID "$devname" 2>/dev/null)
          if [ -n "$luks_uuid" ]; then
            echo "Found LUKS device: $devname with UUID: $luks_uuid"
            luks_dev="$devname"
            break
          fi
        fi
      done
    fi

    if [ -n "$luks_uuid" ]; then
      # Get root filesystem info for additional parameters
      root_fstype=$(findmnt -n -o FSTYPE /)
      root_opts=""

      if [ "$root_fstype" = "btrfs" ]; then
        root_subvol=$(findmnt -n -o OPTIONS / | grep -oP 'subvol=\K[^,]+' || echo "@")
        root_opts="rootflags=subvol=$root_subvol rootfstype=btrfs"
      fi

      # Build dracut-compatible cmdline
      cmdline="rd.luks.uuid=$luks_uuid rd.luks.name=${luks_uuid}=root root=/dev/mapper/root $root_opts rw"
      echo "Generated LUKS cmdline: $cmdline"
    else
      echo "Warning: Could not find LUKS UUID, using mapper fallback"
      cmdline="root=/dev/mapper/root rw"
    fi
  else
    # Unencrypted root
    echo "Unencrypted root detected: $root_source"
    root_uuid=$(findmnt -n -o UUID /)
    if [ -n "$root_uuid" ]; then
      cmdline="root=UUID=$root_uuid rw"
    else
      cmdline="root=$root_source rw"
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
